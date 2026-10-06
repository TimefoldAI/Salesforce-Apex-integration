/**
 * Step two of the round: how does that become a routing problem?
 *
 * Builds the body for POST /api/models/field-service-routing/v1/route-plans.
 * The authoritative schema is
 * https://app.timefold.ai/openapis/field-service-routing/v1
 * and the details below that look arbitrary are all from it, or from a live
 * rejection. They are marked.
 *
 * One engineer becomes one vehicle. One working day becomes one shift on that
 * vehicle, starting and finishing at their home base. One ServiceAppointment
 * becomes one visit. Leave becomes a break on the shift it falls in, and a job
 * a person has already committed to becomes a pinned itinerary item.
 *
 * Distances need no configuration here. The model uses the Timefold Platform's
 * maps service, and the provider is a property of the tenant, not of a request:
 * Settings > Maps provider in the platform. A hosted tenant defaults to OSRM
 * with the map region taken from the coordinates, so these routes are real road
 * distances. The run reports the provider back under config.mapsConfiguration,
 * which is readOnly - a request that tries to set it is ignored.
 */
public with sharing class TimefoldRoutesRequest {

    private static final List<String> WEEKDAYS = new List<String>{
        'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
    };

    /**
     * A Monday, to count weekdays from.
     *
     * Datetime.format('EEEE') would give the day name, but in the running
     * user's locale, and the DayOfWeek picklist on TimeSlot is always English.
     * Counting days from a known Monday cannot be wrong in a German org.
     */
    private static final Date FIRST_MONDAY = Date.newInstance(2024, 1, 1);

    /** What the request left out, so the caller can say so on the run record. */
    public class Notes {
        public Integer vehicles = 0;
        public Integer shifts = 0;
        public Integer visits = 0;
        public Integer visitsWithoutCoordinates = 0;
        public Integer visitsCancelled = 0;
        public Integer breaks = 0;
        public Integer pinned = 0;
        public Integer shiftsDroppedForLeave = 0;
        public List<String> engineersWithoutHome = new List<String>();
        /** Pins asked for that no shift could hold. Reported, never ignored. */
        public List<String> pinsDropped = new List<String>();
    }

    /** One working day of one engineer: the shift a visit can be pinned into. */
    private class Window {
        String id;
        Datetime startsAt;
        Datetime softEnd;
        Datetime hardEnd;
    }

    public static String build(TimefoldRoutesExtract.Problem problem) {
        return build(problem, new Notes());
    }

    public static String build(TimefoldRoutesExtract.Problem problem, Notes notes) {
        Integer overtime = TimefoldRules.count('Routes.OvertimeMinutes');
        Boolean returnHome = TimefoldRules.flag('Routes.ReturnToHome');
        Boolean ownRegion = TimefoldRules.flag('Routes.RestrictToOwnRegion');
        Boolean breaksFromLeave = TimefoldRules.flag('Routes.BreaksFromAbsences');

        Set<String> declaredTags = new Set<String>();
        Set<String> declaredSkills = new Set<String>();
        // Which pins actually made it onto a shift. A visit is told it is
        // pinned only if some shift is holding it, or the run comes back
        // DATASET_INVALID with PinnedVisitStartTimeMissing.
        Set<Id> pinnedOnAShift = new Set<Id>();

        Map<Id, List<TimefoldRoutesExtract.Visit>> pinsByEngineer =
            pinsByEngineer(problem);

        // ---- vehicles: one shift per engineer per working day -------------
        List<Object> vehicles = new List<Object>();
        for (TimefoldRoutesExtract.Technician tech : problem.technicians) {
            if (!tech.hasHome()) {
                // No home base, no route. Recorded rather than guessed at: a
                // made-up starting point would produce a plausible plan whose
                // travel times are all wrong.
                notes.engineersWithoutHome.add(tech.name);
                continue;
            }
            List<Decimal> home = new List<Decimal>{
                tech.homeLatitude, tech.homeLongitude };

            List<Object> skills = new List<Object>();
            List<String> skillNames = new List<String>(tech.skills.keySet());
            skillNames.sort();
            for (String name : skillNames) {
                declaredSkills.add(name);
                skills.add(new Map<String, Object>{
                    'name' => name,
                    'level' => tech.skills.get(name).round().intValue() });
            }

            List<TimefoldRoutesExtract.Visit> theirPins =
                pinsByEngineer.containsKey(tech.recordId)
                    ? pinsByEngineer.get(tech.recordId)
                    : new List<TimefoldRoutesExtract.Visit>();

            List<Object> shifts = new List<Object>();
            for (Window window : workingDays(problem, tech, overtime)) {
                if (breaksFromLeave && coveredByLeave(tech, window)) {
                    // Off for the whole day. A shift with a break across all
                    // of it is not the same statement: the solver would still
                    // count the vehicle as activated and could plan travel.
                    notes.shiftsDroppedForLeave++;
                    continue;
                }
                Map<String, Object> shift = new Map<String, Object>{
                    'id' => window.id,
                    'startLocation' => home,
                    'minStartTime' => iso(window.startsAt),
                    // The rostered end is soft and the overtime allowance is
                    // hard, so the solver runs late only when that beats
                    // leaving a job undone.
                    'maxSoftEndTime' => iso(window.softEnd),
                    'maxEndTime' => iso(window.hardEnd)
                };
                if (returnHome) {
                    shift.put('endLocation', home);
                }
                if (!skills.isEmpty()) {
                    shift.put('skills', skills);
                }
                if (String.isNotBlank(tech.region)) {
                    declaredTags.add(tech.region);
                    shift.put('tags', new List<String>{ tech.region });
                }
                if (breaksFromLeave) {
                    List<Object> breaks = breaksIn(tech, window);
                    if (!breaks.isEmpty()) {
                        shift.put('requiredBreaks', breaks);
                        notes.breaks += breaks.size();
                    }
                }
                List<Object> itinerary =
                    pinnedItinerary(theirPins, window, pinnedOnAShift);
                if (!itinerary.isEmpty()) {
                    shift.put('itinerary', itinerary);
                }
                shifts.add(shift);
            }
            if (shifts.isEmpty()) {
                continue;                   // rostered off for the whole window
            }
            notes.shifts += shifts.size();
            notes.vehicles++;
            // Timefold identifies the vehicle by this id, and the write-back
            // maps it back to a ServiceResource by name. Two engineers with the
            // same name would collide, so TimefoldRoutesWriteback reports that
            // rather than assigning the work to whichever it found first.
            vehicles.add(new Map<String, Object>{
                'id' => tech.name, 'shifts' => shifts });
        }

        // Any pin that no shift could hold. Usually a job scheduled outside
        // the engineer's working hours, or on somebody who is not in the
        // region any more. Named, because silently unpinning a job a
        // dispatcher committed to is the worst of the three options.
        for (TimefoldRoutesExtract.Visit visit : problem.pinnedVisits()) {
            if (!pinnedOnAShift.contains(visit.recordId)) {
                notes.pinsDropped.add(visit.name);
            }
        }
        notes.pinned = pinnedOnAShift.size();

        // ---- visits ---------------------------------------------------------
        List<Object> visits = new List<Object>();
        for (TimefoldRoutesExtract.Visit visit : problem.visits) {
            Boolean pinned = pinnedOnAShift.contains(visit.recordId);
            Map<String, Object> item = new Map<String, Object>{
                'id' => visit.recordId,
                'name' => visit.name,
                'location' => new List<Decimal>{ visit.latitude, visit.longitude },
                'serviceDuration' => 'PT' + visit.durationMinutes + 'M'
            };
            // A pinned visit is sent without its time window on purpose. It is
            // not being planned, it is being told: somebody has already
            // committed to this time, and a window that contradicts it would
            // make the whole dataset invalid rather than override the person.
            if (!pinned && visit.earliest != null && visit.due != null
                    && visit.due > visit.earliest) {
                item.put('timeWindows', new List<Object>{
                    new Map<String, Object>{
                        'minStartTime' => iso(visit.earliest),
                        'maxEndTime' => iso(visit.due) } });
            }
            if (pinned) {
                item.put('pinningRequested', true);
            }
            if (!visit.requiredSkills.isEmpty()) {
                List<String> names = new List<String>(visit.requiredSkills.keySet());
                names.sort();
                List<Object> required = new List<Object>();
                for (String name : names) {
                    declaredSkills.add(name);
                    Decimal level = visit.requiredSkills.get(name);
                    Map<String, Object> one = new Map<String, Object>{ 'name' => name };
                    if (level != null && level > 0) {
                        one.put('minLevel', level.round().intValue());
                    }
                    required.add(one);
                }
                item.put('requiredSkills', required);
            }
            // Keep each region's work with that region's crew.
            if (ownRegion && String.isNotBlank(visit.region)) {
                declaredTags.add(visit.region);
                item.put('requiredTags', new List<String>{ visit.region });
            }
            visits.add(item);
        }
        notes.visits = visits.size();
        notes.visitsWithoutCoordinates = problem.visitsWithoutCoordinates;
        notes.visitsCancelled = problem.visitsCancelled;

        // Every tag and skill a shift or a visit names has to be declared up
        // front. An undeclared one is not a warning: the run comes back
        // DATASET_INVALID, and the validation result names the tag.
        List<String> tagNames = new List<String>(declaredTags);
        tagNames.sort();
        List<Object> tags = new List<Object>();
        for (String name : tagNames) {
            tags.add(new Map<String, Object>{ 'name' => name });
        }
        List<String> skillNames = new List<String>(declaredSkills);
        skillNames.sort();

        Map<String, Object> modelInput = new Map<String, Object>{
            'vehicles' => vehicles,
            'visits' => visits,
            // The shapes differ from Employee Shift Scheduling on purpose:
            // here a tag is an object with a name and a skill is a bare
            // string, where the roster model wants {"id": ...} for both.
            'tags' => tags,
            'skills' => skillNames,
            // And Field Service Routing spells the window startDate/endDate
            // where the roster model says start/end. Same vendor, two models.
            'planningWindow' => new Map<String, Object>{
                'startDate' => iso(problem.windowStart),
                'endDate' => iso(problem.windowEnd)
            }
        };

        Map<String, Object> run = new Map<String, Object>{
            'name' => 'Salesforce field service '
                      + problem.windowStart.formatGmt('yyyy-MM-dd'),
            'termination' => new Map<String, Object>{
                'spentLimit' => 'PT'
                    + Math.max(1, TimefoldRules.count('Routes.SolverSeconds')) + 'S'
            }
        };
        Map<String, Object> config = new Map<String, Object>{ 'run' => run };
        Map<String, Object> weights = TimefoldRules.weights('Routes');
        if (!weights.isEmpty()) {
            config.put('model', new Map<String, Object>{ 'overrides' => weights });
        }

        return JSON.serialize(new Map<String, Object>{
            'config' => config, 'modelInput' => modelInput }, true);
    }

    // ------------------------------------------------------------------ breaks

    /**
     * The leave that falls inside one shift, as FIXED breaks.
     *
     * A ResourceAbsence has a definite start and end, so FIXED is the right
     * shape of the three the schema offers - FLOATING is for "half an hour
     * somewhere in the middle" and LEGACY is deprecated. Clipped to the shift,
     * because a break that starts before its shift is a validation issue of
     * its own.
     */
    private static List<Object> breaksIn(TimefoldRoutesExtract.Technician tech,
                                         Window window) {
        List<Object> breaks = new List<Object>();
        Integer index = 0;
        for (TimefoldRosterExtract.Absence absence : tech.absences) {
            if (absence.endAt <= window.startsAt
                    || absence.startAt >= window.hardEnd) {
                continue;
            }
            // "from" and "to" are reserved words in Apex: the declaration
            // compiles and the use does not.
            Datetime clippedStart = absence.startAt > window.startsAt
                ? absence.startAt : window.startsAt;
            Datetime clippedEnd = absence.endAt < window.hardEnd
                ? absence.endAt : window.hardEnd;
            if (clippedEnd <= clippedStart) {
                continue;
            }
            index++;
            breaks.add(new Map<String, Object>{
                'id' => window.id + '::break-' + index,
                'type' => 'FIXED',
                'startTime' => iso(clippedStart),
                'endTime' => iso(clippedEnd)
            });
        }
        return breaks;
    }

    /** True when leave covers the whole of this shift. */
    private static Boolean coveredByLeave(TimefoldRoutesExtract.Technician tech,
                                          Window window) {
        for (TimefoldRosterExtract.Absence absence : tech.absences) {
            if (absence.startAt <= window.startsAt
                    && absence.endAt >= window.softEnd) {
                return true;
            }
        }
        return false;
    }

    // ------------------------------------------------------------------- pins

    /** The visits that must not move, grouped by the engineer holding them. */
    private static Map<Id, List<TimefoldRoutesExtract.Visit>> pinsByEngineer(
            TimefoldRoutesExtract.Problem problem) {
        Map<Id, List<TimefoldRoutesExtract.Visit>> out =
            new Map<Id, List<TimefoldRoutesExtract.Visit>>();
        for (TimefoldRoutesExtract.Visit visit : problem.pinnedVisits()) {
            Id resourceId = visit.soleResourceId();
            // Pinning says "this engineer, at this time". Without exactly one
            // engineer and a time there is nothing to say, so the visit is
            // left free and reported as a dropped pin.
            if (resourceId == null || visit.scheduledStart == null) {
                continue;
            }
            if (!out.containsKey(resourceId)) {
                out.put(resourceId, new List<TimefoldRoutesExtract.Visit>());
            }
            out.get(resourceId).add(visit);
        }
        return out;
    }

    /**
     * The pinned visits this shift is holding, in the order they happen.
     *
     * Chronological order is required, not tidy: "in case multiple visits on
     * an itinerary are pinned, they need to be chronologically sorted by their
     * startServiceTime".
     */
    private static List<Object> pinnedItinerary(
            List<TimefoldRoutesExtract.Visit> candidates, Window window,
            Set<Id> placed) {
        Map<Long, TimefoldRoutesExtract.Visit> byStart =
            new Map<Long, TimefoldRoutesExtract.Visit>();
        for (TimefoldRoutesExtract.Visit visit : candidates) {
            Datetime startsAt = visit.scheduledStart;
            Datetime finishes = startsAt.addMinutes(visit.durationMinutes);
            // Inside this shift, service included. A pin that runs past the
            // hard end is refused by the model, so it belongs to no shift.
            if (startsAt < window.startsAt || finishes > window.hardEnd) {
                continue;
            }
            // Two pins at the same second on one engineer cannot both be
            // honoured; the first wins and the other is reported.
            if (!byStart.containsKey(startsAt.getTime())) {
                byStart.put(startsAt.getTime(), visit);
            }
        }
        List<Long> order = new List<Long>(byStart.keySet());
        order.sort();

        List<Object> itinerary = new List<Object>();
        for (Long at : order) {
            TimefoldRoutesExtract.Visit visit = byStart.get(at);
            placed.add(visit.recordId);
            itinerary.add(new Map<String, Object>{
                'id' => visit.recordId,
                'kind' => 'VISIT',
                'startServiceTime' => iso(visit.scheduledStart),
                'pin' => true
            });
        }
        return itinerary;
    }

    // --------------------------------------------------------- working days

    /** Every day the engineer is rostered to work, as shift windows. */
    private static List<Window> workingDays(
            TimefoldRoutesExtract.Problem problem,
            TimefoldRoutesExtract.Technician tech, Integer overtime) {
        List<Window> windows = new List<Window>();

        List<TimefoldRosterExtract.DailyWindow> pattern =
            problem.operatingHours.get(tech.operatingHoursId);
        Map<String, List<TimefoldRosterExtract.DailyWindow>> byDay =
            new Map<String, List<TimefoldRosterExtract.DailyWindow>>();
        for (TimefoldRosterExtract.DailyWindow slot :
                (pattern == null
                 ? new List<TimefoldRosterExtract.DailyWindow>() : pattern)) {
            if (!byDay.containsKey(slot.dayOfWeek)) {
                byDay.put(slot.dayOfWeek,
                          new List<TimefoldRosterExtract.DailyWindow>());
            }
            byDay.get(slot.dayOfWeek).add(slot);
        }

        Set<String> fallbackDays = defaultWorkDays();
        Integer startSeconds = TimefoldRules.count('Routes.ShiftStartHour') * 3600;
        Integer endSeconds = TimefoldRules.count('Routes.ShiftEndHour') * 3600;

        Datetime day = problem.windowStart;
        while (day < problem.windowEnd) {
            String name = weekdayOf(day);
            if (byDay.isEmpty()) {
                // No OperatingHours on the territory membership. Fall back to
                // the configured hours, on the configured days: without the
                // day list the solver would happily book a Sunday.
                if (fallbackDays.contains(name)) {
                    windows.add(window(tech, day, startSeconds, endSeconds, overtime));
                }
            } else if (byDay.containsKey(name)) {
                for (TimefoldRosterExtract.DailyWindow slot : byDay.get(name)) {
                    windows.add(window(tech, day, slot.startSeconds,
                                       slot.endSeconds, overtime));
                }
            }
            day = day.addDays(1);
        }
        return windows;
    }

    private static Window window(TimefoldRoutesExtract.Technician tech,
                                 Datetime day, Integer fromSeconds,
                                 Integer toSeconds, Integer overtime) {
        Window shift = new Window();
        shift.startsAt = day.addSeconds(fromSeconds);
        shift.softEnd = day.addSeconds(toSeconds);
        if (shift.softEnd <= shift.startsAt) {
            shift.softEnd = shift.softEnd.addDays(1);   // a shift over midnight
        }
        shift.hardEnd = shift.softEnd.addMinutes(overtime);
        shift.id = tech.name + '::' + shift.startsAt.formatGmt('yyyy-MM-dd')
                 + 'T' + shift.startsAt.formatGmt('HH:mm');
        return shift;
    }

    /** Which days count as working days when there are no OperatingHours. */
    private static Set<String> defaultWorkDays() {
        Set<String> days = new Set<String>();
        String raw = TimefoldRules.text('Routes.DefaultWorkDays');
        for (String piece : (raw == null ? '' : raw).split(';')) {
            if (String.isNotBlank(piece)) {
                days.add(piece.trim());
            }
        }
        return days;
    }

    @TestVisible
    private static String weekdayOf(Datetime value) {
        // Math.mod keeps the sign of the dividend, so a date before the
        // reference Monday would index the list with a negative number.
        Integer offset = Math.mod(
            Math.mod(FIRST_MONDAY.daysBetween(value.dateGmt()), 7) + 7, 7);
        return WEEKDAYS[offset];
    }

    private static String iso(Datetime value) {
        return value.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
    }
}
