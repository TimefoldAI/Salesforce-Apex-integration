/**
 * Step two of the roster: how does that become an optimisation problem?
 *
 * Builds the body for POST /api/models/employee-scheduling/v1/schedules. The
 * authoritative schema is https://app.timefold.ai/openapis/employee-scheduling/v1
 * and several details below are only there because that schema, or a live
 * rejection, said so. They are marked.
 */
public with sharing class TimefoldRosterRequest {

    private static final List<String> WEEKDAYS = new List<String>{
        'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
    };

    /** Tag categories, so a rule can say "count shift types" and be understood. */
    private static final String TAG_TYPE_SHIFT_TYPE = 'shiftType';
    private static final String TAG_TYPE_WARD = 'ward';

    /**
     * A Salesforce TimeSlot cannot cross midnight, so an overnight rota is two
     * rows. Left apart, a night shift running 23:00 to 07:00 fits neither, and
     * every night nurse looks unavailable for their own shift. Spans that touch
     * are joined, and "touch" has to allow the one-second gap between
     * 23:59:59 and 00:00:00.
     */
    private static final Integer MAX_GAP_SECONDS = 1;

    public static String build(TimefoldRosterExtract.Problem problem) {
        Boolean wardEnabled = TimefoldRules.flag('Roster.WardEligibilityEnabled');
        String wardPrefix = TimefoldRules.text('Roster.WardSkillPrefix');
        Boolean respectExisting = TimefoldRules.flag('Roster.RespectExisting');
        Map<String, List<String>> roleSkills = TimefoldRules.roleSkills();

        Map<Id, List<TimefoldRosterExtract.Absence>> absencesByNurse =
            new Map<Id, List<TimefoldRosterExtract.Absence>>();
        for (TimefoldRosterExtract.Absence absence : problem.absences) {
            if (!absencesByNurse.containsKey(absence.resourceId)) {
                absencesByNurse.put(absence.resourceId,
                                    new List<TimefoldRosterExtract.Absence>());
            }
            absencesByNurse.get(absence.resourceId).add(absence);
        }

        // ---- contracts, one per distinct weekly allowance -----------------
        Map<Id, String> contractOf = new Map<Id, String>();
        List<Object> contracts = buildContracts(problem.nurses, contractOf);

        // ---- employees ----------------------------------------------------
        List<Object> employees = new List<Object>();
        for (TimefoldRosterExtract.Nurse nurse : problem.nurses) {
            List<Object> skills = new List<Object>();
            List<String> skillNames = new List<String>(nurse.skills.keySet());
            skillNames.sort();
            for (String name : skillNames) {
                skills.add(new Map<String, Object>{ 'id' => name });
            }
            if (wardEnabled) {
                Set<String> seen = new Set<String>(nurse.wards);
                List<String> wards = new List<String>(seen);
                wards.sort();
                for (String ward : wards) {
                    skills.add(new Map<String, Object>{ 'id' => wardPrefix + ward });
                }
            }

            Map<String, Object> employee = new Map<String, Object>{
                'id' => nurse.name,
                'skills' => skills
            };
            if (contractOf.containsKey(nurse.recordId)) {
                employee.put('contracts',
                             new List<String>{ contractOf.get(nurse.recordId) });
            }

            List<Object> unavailable = new List<Object>();
            for (TimefoldRosterExtract.Absence absence
                    : (absencesByNurse.containsKey(nurse.recordId)
                       ? absencesByNurse.get(nurse.recordId)
                       : new List<TimefoldRosterExtract.Absence>())) {
                if (absence.endAt <= problem.windowStart
                        || absence.startAt >= problem.windowEnd) {
                    continue;
                }
                unavailable.add(new Map<String, Object>{
                    'start' => iso(absence.startAt > problem.windowStart
                                   ? absence.startAt : problem.windowStart),
                    'end'   => iso(absence.endAt < problem.windowEnd
                                   ? absence.endAt : problem.windowEnd)
                });
            }
            if (!unavailable.isEmpty()) {
                employee.put('unavailableTimeSpans', unavailable);
            }

            List<Object> available = availabilitySpans(
                problem.operatingHours.get(nurse.operatingHoursId),
                problem.windowStart, problem.windowEnd);
            if (!available.isEmpty()) {
                employee.put('availableTimeSpans', available);
            }
            employees.add(employee);
        }

        // ---- shifts -------------------------------------------------------
        List<Object> shifts = new List<Object>();
        Map<String, String> tagTypeOf = new Map<String, String>();
        for (TimefoldRosterExtract.ShiftDemand demand : problem.shifts) {
            List<String> required = new List<String>();
            if (demand.role != null && roleSkills.containsKey(demand.role)) {
                required.addAll(roleSkills.get(demand.role));
            }
            // Ward eligibility is expressed as a synthetic skill, so one
            // mechanism covers both certificates and wards, and a nurse who is
            // a member of two wards simply holds two ward skills and can float.
            if (wardEnabled && String.isNotBlank(demand.ward)) {
                required.add(wardPrefix + demand.ward);
            }

            List<String> tags = new List<String>();
            String shiftType = demand.shiftType();
            if (String.isNotBlank(shiftType)) {
                tags.add(shiftType);
                tagTypeOf.put(shiftType, TAG_TYPE_SHIFT_TYPE);
            }
            if (String.isNotBlank(demand.ward)) {
                tags.add(demand.ward);
                tagTypeOf.put(demand.ward, TAG_TYPE_WARD);
            }

            Map<String, Object> shift = new Map<String, Object>{
                'id' => String.valueOf(demand.recordId),
                'start' => iso(demand.startAt),
                'end' => iso(demand.endAt),
                'tags' => tags
            };
            if (!required.isEmpty()) {
                shift.put('requiredSkills', required);
                // MATCH_ALL, not ALL. The enum is in the OpenAPI schema and the
                // documentation example does not set the field at all, so
                // nothing gives this away until a request is rejected.
                shift.put('requiredSkillsMatchKind', 'MATCH_ALL');
            }
            // A shift already staffed in Salesforce can be honoured rather than
            // re-planned. Off by default: after one run every shift is
            // assigned, so with it on a second run has everything pinned and
            // can change nothing at all.
            if (respectExisting && demand.assignedResourceId != null) {
                TimefoldRosterExtract.Nurse who =
                    problem.nurseById(demand.assignedResourceId);
                if (who != null) {
                    shift.put('employee', who.name);
                    shift.put('pinned', true);
                }
            }
            shifts.add(shift);
        }

        List<Object> tags = new List<Object>();
        List<String> tagNames = new List<String>(tagTypeOf.keySet());
        tagNames.sort();
        for (String name : tagNames) {
            tags.add(new Map<String, Object>{
                'id' => name, 'tagType' => tagTypeOf.get(name) });
        }

        Map<String, Object> modelInput = new Map<String, Object>{
            'employees' => employees,
            'shifts' => shifts,
            'contracts' => contracts,
            'tagTypes' => new List<Object>{
                new Map<String, Object>{ 'id' => TAG_TYPE_SHIFT_TYPE },
                new Map<String, Object>{ 'id' => TAG_TYPE_WARD }
            },
            'tags' => tags,
            // Employee Shift Scheduling calls this start/end. Field Service
            // Routing calls the same idea startDate/endDate. Same vendor, two
            // models, two spellings.
            'planningWindow' => new Map<String, Object>{
                'start' => iso(problem.windowStart),
                'end' => iso(problem.windowEnd)
            },
            'scheduleParameterization' => new Map<String, Object>{
                'weekStart' => 'MONDAY'
            }
        };

        Map<String, Object> run = new Map<String, Object>{
            'name' => 'Salesforce roster ' + problem.windowStart.formatGmt('yyyy-MM-dd'),
            'termination' => new Map<String, Object>{
                'spentLimit' => 'PT'
                    + Math.max(1, TimefoldRules.count('Roster.SolverSeconds')) + 'S'
            }
        };
        Map<String, Object> config = new Map<String, Object>{ 'run' => run };
        Map<String, Object> weights = TimefoldRules.weights('Roster');
        if (!weights.isEmpty()) {
            config.put('model', new Map<String, Object>{ 'overrides' => weights });
        }

        return JSON.serialize(new Map<String, Object>{
            'config' => config, 'modelInput' => modelInput }, true);
    }

    /**
     * One contract per distinct weekly hour allowance.
     *
     * The hours come from Salesforce. Everything else - rest, consecutive days,
     * shift-type variety, weekend load - comes from the rules and is identical
     * across contracts.
     */
    private static List<Object> buildContracts(
            List<TimefoldRosterExtract.Nurse> nurses, Map<Id, String> contractOf) {

        Integer restMinutes =
            (Integer) (TimefoldRules.number('Roster.MinimumRestHours') * 60).round();
        Integer maxConsecutive = TimefoldRules.count('Roster.MaximumConsecutiveDays');
        Integer maxShiftTypes = TimefoldRules.count('Roster.MaximumShiftTypesPerWeek');
        Integer maxWeekends = TimefoldRules.count('Roster.MaximumWeekendsInWindow');
        Integer weekendWeeks = TimefoldRules.count('Roster.WeekendWindowWeeks');
        Decimal minimumFraction = TimefoldRules.number('Roster.ContractHoursMinimumFraction');
        String contractHoursSat = TimefoldRules.text('Roster.ContractHoursSatisfiability');

        Map<String, Object> byId = new Map<String, Object>();

        for (TimefoldRosterExtract.Nurse nurse : nurses) {
            Integer weekly = nurse.capacityHoursPerMonth == null
                ? null
                : (Integer) (nurse.capacityHoursPerMonth * 12 / 52).round();
            String contractId = weekly == null
                ? 'contract-default'
                : 'contract-' + weekly + 'h-per-week';
            contractOf.put(nurse.recordId, contractId);
            if (byId.containsKey(contractId)) {
                continue;
            }

            Map<String, Object> contract = new Map<String, Object>{ 'id' => contractId };

            if (restMinutes > 0) {
                contract.put('minutesBetweenShiftsRules', new List<Object>{
                    new Map<String, Object>{
                        // Rule ids are bound as object ids across the WHOLE
                        // dataset, not per contract. Two contracts sharing a
                        // rule id is rejected with DATASET_INVALID, so every id
                        // is scoped by its contract.
                        'id' => contractId + '::rest-' + restMinutes + 'min',
                        'minimumMinutesBetweenShifts' => restMinutes,
                        'satisfiability' =>
                            TimefoldRules.text('Roster.MinimumRestSatisfiability')
                    }
                });
            }
            if (maxConsecutive != null) {
                contract.put('consecutiveDaysWorkedRules', new List<Object>{
                    new Map<String, Object>{
                        'id' => contractId + '::max-' + maxConsecutive + '-consecutive-days',
                        'maximum' => maxConsecutive,
                        'satisfiability' =>
                            TimefoldRules.text('Roster.MaximumConsecutiveSatisfiability')
                    }
                });
            }

            List<Object> periodRules = new List<Object>();
            if (weekly != null) {
                Map<String, Object> workedLimit = new Map<String, Object>{
                    'minutesWorkedMax' => weekly * 60
                };
                // A maximum alone does not spread the work: leaving somebody
                // idle costs nothing, so the solver is happy to run a ward with
                // two people. A preferred minimum is what makes an under-used
                // nurse register as a penalty, and Timefold only allows a
                // minimum on a PREFERRED rule.
                if (minimumFraction != null && contractHoursSat == 'PREFERRED') {
                    workedLimit.put('minutesWorkedMin',
                              (Integer) (weekly * 60 * minimumFraction).round());
                }
                periodRules.add(new Map<String, Object>{
                    'id' => contractId + '::max-' + weekly + 'h-per-week',
                    'period' => 'WEEK',
                    'minutesWorkedLimit' => workedLimit,
                    'satisfiability' => contractHoursSat
                });
            }
            if (maxShiftTypes != null) {
                periodRules.add(new Map<String, Object>{
                    'id' => contractId + '::max-' + maxShiftTypes + '-shift-types-per-week',
                    'period' => 'WEEK',
                    'shiftTypesTagCategories' => new List<String>{ TAG_TYPE_SHIFT_TYPE },
                    'shiftTypesWorkedMax' => maxShiftTypes,
                    'satisfiability' =>
                        TimefoldRules.text('Roster.MaximumShiftTypesSatisfiability')
                });
            }
            if (!periodRules.isEmpty()) {
                contract.put('periodRules', periodRules);
            }

            // "At most one weekend in any two" cannot be a WEEK period rule,
            // because a week only ever contains one weekend: the rule would be
            // valid, accepted, and have no effect whatsoever. It needs a window
            // that slides across week boundaries.
            if (maxWeekends != null && weekendWeeks != null) {
                contract.put('rollingWindowRules', new List<Object>{
                    new Map<String, Object>{
                        'id' => contractId + '::max-' + maxWeekends
                                + '-weekends-per-' + weekendWeeks + '-weeks',
                        'rollingWindow' => new Map<String, Object>{
                            'type' => 'WEEKLY', 'size' => weekendWeeks },
                        'weekendsLimit' => new Map<String, Object>{
                            'weekendsWorkedMax' => maxWeekends },
                        'satisfiability' =>
                            TimefoldRules.text('Roster.MaximumWeekendsSatisfiability')
                    }
                });
            }
            byId.put(contractId, contract);
        }
        return byId.values();
    }

    /**
     * Expand weekly operating hours across the planning window.
     *
     * Returns nothing when the hours already cover every hour of every day,
     * because restricting availability to "always" only adds a fortnight of
     * redundant spans to every nurse in the payload.
     */
    @TestVisible
    private static List<Object> availabilitySpans(
            List<TimefoldRosterExtract.DailyWindow> windows,
            Datetime windowStart, Datetime windowEnd) {

        List<Object> out = new List<Object>();
        if (windows == null || windows.isEmpty()) {
            return out;
        }

        Map<String, List<TimefoldRosterExtract.DailyWindow>> byDay =
            new Map<String, List<TimefoldRosterExtract.DailyWindow>>();
        for (TimefoldRosterExtract.DailyWindow w : windows) {
            if (!byDay.containsKey(w.dayOfWeek)) {
                byDay.put(w.dayOfWeek, new List<TimefoldRosterExtract.DailyWindow>());
            }
            byDay.get(w.dayOfWeek).add(w);
        }
        if (byDay.size() >= 7 && coversEveryDay(byDay)) {
            return out;
        }

        List<Long> starts = new List<Long>();
        List<Long> ends = new List<Long>();
        Datetime day = windowStart;
        while (day < windowEnd) {
            String weekday = WEEKDAYS[dayIndex(day)];
            for (TimefoldRosterExtract.DailyWindow w
                    : (byDay.containsKey(weekday)
                       ? byDay.get(weekday)
                       : new List<TimefoldRosterExtract.DailyWindow>())) {
                Datetime spanStart = day.addSeconds(w.startSeconds);
                Datetime finish = day.addSeconds(w.endSeconds);
                if (w.wrapsMidnight) {
                    finish = finish.addDays(1);
                }
                if (spanStart < windowStart) { spanStart = windowStart; }
                if (finish > windowEnd) { finish = windowEnd; }
                if (finish > spanStart) {
                    starts.add(spanStart.getTime());
                    ends.add(finish.getTime());
                }
            }
            day = day.addDays(1);
        }
        return mergeSpans(starts, ends);
    }

    /** Sort spans and join any that touch or overlap. */
    private static List<Object> mergeSpans(List<Long> starts, List<Long> ends) {
        List<Object> out = new List<Object>();
        if (starts.isEmpty()) {
            return out;
        }
        // Insertion sort on a pair of lists: the spans are generated a day at
        // a time so they are nearly ordered already, and there are at most a
        // few dozen.
        for (Integer i = 1; i < starts.size(); i++) {
            Long s = starts[i], e = ends[i];
            Integer j = i - 1;
            while (j >= 0 && starts[j] > s) {
                starts[j + 1] = starts[j];
                ends[j + 1] = ends[j];
                j--;
            }
            starts[j + 1] = s;
            ends[j + 1] = e;
        }

        Long openFrom = starts[0], openTo = ends[0];
        for (Integer i = 1; i < starts.size(); i++) {
            if (starts[i] - openTo <= MAX_GAP_SECONDS * 1000) {
                openTo = Math.max(openTo, ends[i]);
            } else {
                out.add(span(openFrom, openTo));
                openFrom = starts[i];
                openTo = ends[i];
            }
        }
        out.add(span(openFrom, openTo));
        return out;
    }

    private static Map<String, Object> span(Long fromMillis, Long toMillis) {
        return new Map<String, Object>{
            'start' => iso(Datetime.newInstance(fromMillis)),
            'end' => iso(Datetime.newInstance(toMillis))
        };
    }

    private static Boolean coversEveryDay(
            Map<String, List<TimefoldRosterExtract.DailyWindow>> byDay) {
        for (List<TimefoldRosterExtract.DailyWindow> windows : byDay.values()) {
            Boolean whole = false;
            for (TimefoldRosterExtract.DailyWindow w : windows) {
                if (w.startSeconds <= 0 && w.endSeconds >= 86340) {
                    whole = true;
                }
            }
            if (!whole) {
                return false;
            }
        }
        return true;
    }

    /** Monday is 0, to match WEEKDAYS. */
    @TestVisible
    private static Integer dayIndex(Datetime value) {
        // 1970-01-01 was a Thursday, which is index 3.
        Long days = value.getTime() / 86400000L;
        Integer index = (Integer) Math.mod(days + 3, 7);
        return index;
    }

    private static String iso(Datetime value) {
        return value.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
    }
}
