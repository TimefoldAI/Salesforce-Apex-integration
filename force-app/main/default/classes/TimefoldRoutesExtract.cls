/**
 * Step one of the round: what does Salesforce know about the day's work?
 *
 * Field Service already stores a routing problem. A ServiceAppointment is a
 * visit: it has coordinates, a duration, an arrival window and a parent
 * WorkOrder that says which certificates the job needs. A ServiceResource that
 * is a member of one of the territories is an engineer, and the membership
 * carries their home base and their working pattern. Nothing here is custom.
 *
 * Reads, and nothing else. The same discipline as TimefoldRosterExtract: plain
 * SOQL, no sub-queries, no relative date literals.
 */
public with sharing class TimefoldRoutesExtract {

    /** An engineer, and what they can do and where they start. */
    public class Technician {
        public Id recordId;
        public String name;
        public Map<String, Decimal> skills = new Map<String, Decimal>();
        public Decimal homeLatitude;
        public Decimal homeLongitude;
        public String region;                       // ServiceTerritory.Name
        public Id operatingHoursId;
        /** Leave and other time off, inside the planning window. */
        public List<TimefoldRosterExtract.Absence> absences =
            new List<TimefoldRosterExtract.Absence>();

        public Boolean hasHome() {
            return homeLatitude != null && homeLongitude != null;
        }
    }

    /** A job that needs visiting. */
    public class Visit {
        public Id recordId;                         // ServiceAppointment id
        public Id parentRecordId;                   // usually the WorkOrder
        public String name;
        public Decimal latitude;
        public Decimal longitude;
        public Integer durationMinutes;
        public Datetime earliest;
        public Datetime due;
        public String region;
        public Map<String, Decimal> requiredSkills = new Map<String, Decimal>();
        public String status;
        public String statusCategory;
        public Datetime scheduledStart;
        public Set<Id> assignedResourceIds = new Set<Id>();

        /** True when a dispatcher ticked Pinned in the console. */
        public Boolean pinnedInConsole = false;

        /**
         * Why this visit must not move, or null if it may.
         *
         * Set by TimefoldRoutesExtract, read by TimefoldRoutesRequest, and
         * carried as a sentence rather than a flag because "the solver left it
         * alone" is a question somebody always asks.
         */
        public String pinReason;

        public Boolean isPinned() {
            return pinReason != null;
        }

        /** The one engineer on this appointment, or null if 0 or more than 1. */
        public Id soleResourceId() {
            return assignedResourceIds.size() == 1
                ? new List<Id>(assignedResourceIds)[0] : null;
        }

        /**
         * What Timefold would have written for this placement.
         *
         * The provenance check compares this against the signature the last
         * run recorded, so both sides go through placementOf().
         */
        public String placement() {
            return placementOf(recordId, soleResourceId(), scheduledStart);
        }
    }

    /** Everything one routing run needs. */
    public class Problem {
        public List<Technician> technicians = new List<Technician>();
        public List<Visit> visits = new List<Visit>();
        public Map<Id, List<TimefoldRosterExtract.DailyWindow>> operatingHours =
            new Map<Id, List<TimefoldRosterExtract.DailyWindow>>();
        /** Territory id -> name, for the whole subtree under the root. */
        public Map<Id, String> regions = new Map<Id, String>();
        public Datetime windowStart;
        public Datetime windowEnd;
        /** Appointments in the window that Salesforce has not geocoded yet. */
        public Integer visitsWithoutCoordinates = 0;
        /** Cancelled appointments, left out of the problem entirely. */
        public Integer visitsCancelled = 0;

        public List<Visit> pinnedVisits() {
            List<Visit> pinned = new List<Visit>();
            for (Visit visit : visits) {
                if (visit.isPinned()) {
                    pinned.add(visit);
                }
            }
            return pinned;
        }
    }

    /**
     * Read the routing problem.
     *
     * The window starts at the earliest appointment in scope rather than at
     * today, for the same reason the roster does: a demo org seeded last week
     * must still have something to plan. A production caller that wants "from
     * now" passes its own start.
     */
    public static Problem run(Integer days) {
        return run(days, null);
    }

    public static Problem run(Integer days, Datetime windowStart) {
        Problem problem = new Problem();
        problem.regions = territorySubtree(TimefoldRules.text('Routes.RootTerritory'));
        if (problem.regions.isEmpty()) {
            throw new TimefoldClient.TimefoldException(
                'No ServiceTerritory called "'
                + TimefoldRules.text('Routes.RootTerritory') + '" exists, so there '
                + 'is no field service region to plan. Seed the demo data first: '
                + 'sf apex run --file scripts/apex/seed.apex, or point the '
                + 'Routes.RootTerritory Timefold Setting at the territory you use.');
        }

        Datetime startsAt = windowStart == null
            ? earliestAppointment(problem.regions.keySet()) : windowStart;
        if (startsAt == null) {
            throw new TimefoldClient.TimefoldException(
                'There are no ServiceAppointment records under "'
                + TimefoldRules.text('Routes.RootTerritory') + '" to plan. Seed '
                + 'the demo data first: sf apex run --file scripts/apex/seed.apex');
        }
        problem.windowStart = Datetime.newInstanceGmt(
            startsAt.dateGmt(), Time.newInstance(0, 0, 0, 0));
        problem.windowEnd = problem.windowStart.addDays(days);

        loadVisits(problem);
        loadRequiredSkills(problem);
        loadAssignments(problem);
        loadTechnicians(problem);
        loadOperatingHours(problem);
        loadAbsences(problem);
        markPinned(problem);
        return problem;
    }

    // ------------------------------------------------------------- territories

    /**
     * The root territory and everything under it, by id.
     *
     * SOQL has no recursive query, and Field Service hierarchies are shallow,
     * so this walks down a level at a time. Bounded at five so a territory
     * that is somehow its own ancestor cannot loop for ever.
     */
    @TestVisible
    private static Map<Id, String> territorySubtree(String rootName) {
        Map<Id, String> found = new Map<Id, String>();
        if (String.isBlank(rootName)) {
            return found;
        }
        for (ServiceTerritory row : [
                SELECT Id, Name FROM ServiceTerritory
                WHERE Name = :rootName AND IsActive = TRUE LIMIT 10]) {
            found.put(row.Id, row.Name);
        }
        if (found.isEmpty()) {
            return found;
        }
        Set<Id> frontier = new Set<Id>(found.keySet());
        for (Integer depth = 0; depth < 5 && !frontier.isEmpty(); depth++) {
            Set<Id> next = new Set<Id>();
            for (ServiceTerritory row : [
                    SELECT Id, Name FROM ServiceTerritory
                    WHERE ParentTerritoryId IN :frontier AND IsActive = TRUE
                    LIMIT 500]) {
                if (!found.containsKey(row.Id)) {
                    found.put(row.Id, row.Name);
                    next.add(row.Id);
                }
            }
            frontier = next;
        }
        return found;
    }

    private static Datetime earliestAppointment(Set<Id> regionIds) {
        List<ServiceAppointment> rows = [
            SELECT EarliestStartTime FROM ServiceAppointment
            WHERE ServiceTerritoryId IN :regionIds
              AND EarliestStartTime != NULL
            ORDER BY EarliestStartTime ASC LIMIT 1];
        return rows.isEmpty() ? null : rows[0].EarliestStartTime;
    }

    // ------------------------------------------------------------------ visits

    /**
     * FSL__Pinned__c, but only if this org has it.
     *
     * It is the dispatcher's own "do not move this" checkbox in the console,
     * and the most direct statement of intent there is - so it is worth
     * reading. It belongs to the Field Service managed package, which this
     * repository does not require, and Apex does not fail at run time on a
     * field the org lacks: it fails to compile. Hence a describe and a
     * dynamic query rather than the static SOQL everywhere else here.
     */
    @TestVisible
    private static Boolean orgHasPinnedField() {
        return ServiceAppointment.SObjectType.getDescribe()
            .fields.getMap().containsKey('fsl__pinned__c');
    }

    private static void loadVisits(Problem problem) {
        Set<Id> regionIds = problem.regions.keySet();
        Boolean readPin = orgHasPinnedField();
        Datetime windowStart = problem.windowStart;
        Datetime windowEnd = problem.windowEnd;
        String soql =
            'SELECT Id, Subject, Status, StatusCategory, Duration, DurationType, '
            + 'EarliestStartTime, DueDate, SchedStartTime, Latitude, Longitude, '
            + 'ServiceTerritoryId, ParentRecordId, ServiceTerritory.Name'
            + (readPin ? ', FSL__Pinned__c' : '')
            + ' FROM ServiceAppointment'
            + ' WHERE ServiceTerritoryId IN :regionIds'
            + '   AND EarliestStartTime >= :windowStart'
            + '   AND EarliestStartTime < :windowEnd'
            + ' ORDER BY EarliestStartTime ASC LIMIT 2000';

        for (ServiceAppointment row :
                (List<ServiceAppointment>) Database.query(soql)) {
            // A cancelled job is not work. Left out of the problem entirely
            // rather than pinned, so the solver neither plans it nor counts it.
            if (SKIP_CATEGORIES.contains(row.StatusCategory)) {
                problem.visitsCancelled++;
                continue;
            }
            // No coordinates, no route. Salesforce geocodes an address
            // asynchronously, so a freshly seeded appointment can arrive here
            // with nothing to route to; skipping it is the only honest answer,
            // and TimefoldRoutesRequest reports how many were skipped.
            if (row.Latitude == null || row.Longitude == null) {
                problem.visitsWithoutCoordinates++;
                continue;
            }
            Visit visit = new Visit();
            visit.recordId = row.Id;
            visit.parentRecordId = row.ParentRecordId;
            // String.valueOf around the id on purpose: a ternary whose
            // branches are Id and String is typed as Id, and Apex then tries
            // to convert the subject into one - "Invalid id: Electrical Safety
            // Check". The field is a String either way.
            visit.name = String.isBlank(row.Subject)
                ? String.valueOf(row.Id) : row.Subject;
            visit.latitude = row.Latitude;
            visit.longitude = row.Longitude;
            visit.durationMinutes = toMinutes(row.Duration, row.DurationType);
            visit.earliest = row.EarliestStartTime;
            visit.due = row.DueDate;
            visit.region = String.isBlank(row.ServiceTerritory.Name)
                ? problem.regions.get(row.ServiceTerritoryId)
                : row.ServiceTerritory.Name;
            visit.status = row.Status;
            visit.statusCategory = row.StatusCategory;
            visit.scheduledStart = row.SchedStartTime;
            if (readPin) {
                visit.pinnedInConsole =
                    row.get('FSL__Pinned__c') == true;
            }
            problem.visits.add(visit);
        }
    }

    /** ServiceAppointment.Duration is in Minutes or Hours, per DurationType. */
    @TestVisible
    private static Integer toMinutes(Decimal duration, String unit) {
        if (duration == null) {
            return 60;
        }
        Boolean hours = unit != null && unit.toLowerCase().startsWith('hour');
        return (hours ? duration * 60 : duration).round().intValue();
    }

    /**
     * Which certificates each visit demands.
     *
     * Held against the parent WorkOrder rather than the appointment, because
     * that is where Field Service puts them: SkillRequirement.RelatedRecordId
     * is polymorphic and points at the WorkOrder, WorkType or JobProfile.
     */
    private static void loadRequiredSkills(Problem problem) {
        Map<Id, List<Visit>> byParent = new Map<Id, List<Visit>>();
        for (Visit visit : problem.visits) {
            if (visit.parentRecordId == null) {
                continue;
            }
            if (!byParent.containsKey(visit.parentRecordId)) {
                byParent.put(visit.parentRecordId, new List<Visit>());
            }
            byParent.get(visit.parentRecordId).add(visit);
        }
        if (byParent.isEmpty()) {
            return;
        }
        Set<Id> parents = byParent.keySet();
        for (SkillRequirement row : [
                SELECT RelatedRecordId, SkillLevel, Skill.MasterLabel
                FROM SkillRequirement
                WHERE RelatedRecordId IN :parents
                LIMIT 5000]) {
            if (String.isBlank(row.Skill.MasterLabel)) {
                continue;
            }
            for (Visit visit : byParent.get(row.RelatedRecordId)) {
                visit.requiredSkills.put(row.Skill.MasterLabel,
                                         row.SkillLevel == null ? 0 : row.SkillLevel);
            }
        }
    }

    /** Who is on each appointment now, so a re-plan does not duplicate links. */
    private static void loadAssignments(Problem problem) {
        Map<Id, Visit> byId = new Map<Id, Visit>();
        for (Visit visit : problem.visits) {
            byId.put(visit.recordId, visit);
        }
        if (byId.isEmpty()) {
            return;
        }
        Set<Id> visitIds = byId.keySet();
        // IsPrimaryResource is deliberately not selected. It exists only when
        // certain Field Service options are switched on - this org does not
        // have it - and an Apex query naming a field the org lacks does not
        // fail at run time, it fails to compile. The link works without it.
        for (AssignedResource row : [
                SELECT ServiceAppointmentId, ServiceResourceId
                FROM AssignedResource
                WHERE ServiceAppointmentId IN :visitIds
                LIMIT 5000]) {
            Visit visit = byId.get(row.ServiceAppointmentId);
            if (visit != null && row.ServiceResourceId != null) {
                visit.assignedResourceIds.add(row.ServiceResourceId);
            }
        }
    }

    // ------------------------------------------------------------- engineers

    private static void loadTechnicians(Problem problem) {
        Set<Id> regionIds = problem.regions.keySet();

        // Membership decides who is in scope, so it is read first. Type 'P'
        // last, so a primary membership overwrites a secondary one and wins on
        // region, home base and working pattern.
        Map<Id, ServiceTerritoryMember> memberOf =
            new Map<Id, ServiceTerritoryMember>();
        for (ServiceTerritoryMember row : [
                SELECT ServiceResourceId, ServiceTerritoryId, TerritoryType,
                       OperatingHoursId, Latitude, Longitude,
                       ServiceTerritory.Name
                FROM ServiceTerritoryMember
                WHERE ServiceTerritoryId IN :regionIds
                ORDER BY TerritoryType DESC
                LIMIT 5000]) {
            memberOf.put(row.ServiceResourceId, row);
        }
        if (memberOf.isEmpty()) {
            return;
        }

        Set<Id> resourceIds = memberOf.keySet();
        Map<Id, Technician> byId = new Map<Id, Technician>();
        for (ServiceResource row : [
                SELECT Id, Name, LastKnownLatitude, LastKnownLongitude
                FROM ServiceResource
                WHERE Id IN :resourceIds
                  AND IsActive = TRUE
                  AND ResourceType IN ('T', 'A', 'C')
                ORDER BY Name ASC
                LIMIT 2000]) {
            Technician tech = new Technician();
            tech.recordId = row.Id;
            tech.name = row.Name;
            tech.homeLatitude = row.LastKnownLatitude;
            tech.homeLongitude = row.LastKnownLongitude;

            ServiceTerritoryMember member = memberOf.get(row.Id);
            tech.region = member.ServiceTerritory.Name;
            tech.operatingHoursId = member.OperatingHoursId;
            // The membership is the better source for a home base: it is where
            // this territory expects the engineer to start, while
            // LastKnownLatitude is wherever the mobile app last saw them.
            if (member.Latitude != null && member.Longitude != null) {
                tech.homeLatitude = member.Latitude;
                tech.homeLongitude = member.Longitude;
            }
            byId.put(row.Id, tech);
        }

        for (ServiceResourceSkill row : [
                SELECT ServiceResourceId, SkillLevel, Skill.MasterLabel
                FROM ServiceResourceSkill
                WHERE ServiceResourceId IN :resourceIds
                LIMIT 5000]) {
            Technician tech = byId.get(row.ServiceResourceId);
            if (tech != null && String.isNotBlank(row.Skill.MasterLabel)) {
                tech.skills.put(row.Skill.MasterLabel,
                                row.SkillLevel == null ? 0 : row.SkillLevel);
            }
        }

        problem.technicians = byId.values();
    }

    private static void loadOperatingHours(Problem problem) {
        Set<Id> wanted = new Set<Id>();
        for (Technician tech : problem.technicians) {
            if (tech.operatingHoursId != null) {
                wanted.add(tech.operatingHoursId);
            }
        }
        if (wanted.isEmpty()) {
            return;
        }
        for (TimeSlot row : [
                SELECT OperatingHoursId, DayOfWeek, StartTime, EndTime
                FROM TimeSlot
                WHERE OperatingHoursId IN :wanted
                LIMIT 5000]) {
            TimefoldRosterExtract.DailyWindow window =
                new TimefoldRosterExtract.DailyWindow();
            window.dayOfWeek = row.DayOfWeek;
            window.startSeconds = seconds(row.StartTime);
            window.endSeconds = seconds(row.EndTime);
            window.wrapsMidnight = window.endSeconds <= window.startSeconds;
            if (!problem.operatingHours.containsKey(row.OperatingHoursId)) {
                problem.operatingHours.put(row.OperatingHoursId,
                    new List<TimefoldRosterExtract.DailyWindow>());
            }
            problem.operatingHours.get(row.OperatingHoursId).add(window);
        }
    }

    // ---------------------------------------------------------------- absences

    /**
     * Leave and other time off, per engineer, clipped to the window.
     *
     * Without these, a plan drives straight through a lunch break the Gantt
     * draws. TimefoldRoutesRequest turns each one into a FIXED break on
     * the shift it falls in, or drops the shift when it covers the whole day.
     */
    private static void loadAbsences(Problem problem) {
        if (problem.technicians.isEmpty()) {
            return;
        }
        Map<Id, Technician> byId = new Map<Id, Technician>();
        for (Technician tech : problem.technicians) {
            byId.put(tech.recordId, tech);
        }
        Set<Id> resourceIds = byId.keySet();
        for (ResourceAbsence row : [
                SELECT ResourceId, Type, Start, End FROM ResourceAbsence
                WHERE ResourceId IN :resourceIds
                  AND End >= :problem.windowStart
                  AND Start < :problem.windowEnd
                ORDER BY Start ASC
                LIMIT 2000]) {
            Technician tech = byId.get(row.ResourceId);
            if (tech == null || row.Start == null || row.End == null) {
                continue;
            }
            TimefoldRosterExtract.Absence absence =
                new TimefoldRosterExtract.Absence();
            absence.resourceId = row.ResourceId;
            absence.kind = row.Type;
            absence.startAt = row.Start;
            absence.endAt = row.End;
            tech.absences.add(absence);
        }
    }

    // ----------------------------------------------------------- what to pin

    /** Status categories that mean the job is no longer schedulable at all. */
    private static final Set<String> SKIP_CATEGORIES = new Set<String>{
        'Canceled', 'Cancelled'
    };

    /**
     * Decide which visits must not move, and say why.
     *
     * Three signals, strongest first, and the third is the interesting one:
     *
     *   1. FSL__Pinned__c - a dispatcher ticked "Pinned" in the console. There
     *      is no clearer statement of intent than that.
     *   2. The status category is past Scheduled - Dispatched, In Progress,
     *      Completed, Cannot Complete. The job has been sent to an engineer or
     *      already started, so moving it is not a planning decision any more.
     *   3. It is scheduled, and Timefold did not schedule it there. This is
     *      how a manual assignment is told apart from an automatic one:
     *      every run records what it wrote on Timefold_Run__c, and a
     *      placement that does not match the last recorded plan was made by
     *      a person.
     *
     * Signal 3 is skipped when there is no recorded plan at all, which matters
     * on a first run: an org whose appointments were scheduled by Salesforce's
     * own optimiser before Timefold ever ran would otherwise arrive completely
     * pinned, and the first run would be allowed to change nothing.
     */
    private static void markPinned(Problem problem) {
        if (!TimefoldRules.flag('Routes.RespectExisting')) {
            return;
        }
        Set<String> pinnedCategories =
            splitOn(TimefoldRules.text('Routes.PinnedStatusCategories'));
        Set<String> lastPlan = lastRecordedPlan();

        for (Visit visit : problem.visits) {
            if (visit.pinnedInConsole) {
                visit.pinReason = 'Pinned in the dispatcher console.';
                continue;
            }
            if (pinnedCategories.contains(visit.statusCategory)) {
                visit.pinReason = 'Status is ' + visit.status
                    + ', so the job is already with an engineer.';
                continue;
            }
            String placement = visit.placement();
            if (placement == null || lastPlan.isEmpty()) {
                continue;
            }
            if (!lastPlan.contains(placement)) {
                visit.pinReason = 'Scheduled by hand, not by the last run.';
            }
        }
    }

    /**
     * The placements the most recent finished routing run wrote.
     *
     * Kept on the run record rather than in a field on ServiceAppointment,
     * because the answer itself deliberately lands only on standard fields.
     * The provenance belongs to the run that created it anyway.
     */
    @TestVisible
    private static Set<String> lastRecordedPlan() {
        Set<String> placements = new Set<String>();
        // A Long Text Area cannot be filtered in SOQL - "field
        // 'Plan_Signature__c' can not be filtered in a query call" - so the
        // last few runs are read and the newest one that decided anything
        // wins. Falling back past a run that wrote nothing is right anyway:
        // it is still the last thing Timefold actually decided.
        for (Timefold_Run__c run : [
                SELECT Plan_Signature__c FROM Timefold_Run__c
                WHERE Model__c = 'Routes' AND Status__c = 'Done'
                ORDER BY CreatedDate DESC LIMIT 5]) {
            if (String.isBlank(run.Plan_Signature__c)) {
                continue;
            }
            List<String> lines = run.Plan_Signature__c.split('\n');
            if (lines.isEmpty() || lines[0].trim() != SIGNATURE_VERSION) {
                continue;               // written by an older shape of this code
            }
            for (Integer i = 1; i < lines.size(); i++) {
                if (String.isNotBlank(lines[i])) {
                    placements.add(lines[i].trim());
                }
            }
            return placements;
        }
        return placements;
    }

    /**
     * The first line of a plan signature this class knows how to read.
     *
     * Bump it whenever placementOf() changes shape. An older or unknown
     * header is ignored rather than compared, so a format change frees every
     * visit instead of pinning every visit.
     */
    public static final String SIGNATURE_VERSION = 'signature-v1';

    /**
     * One placement, as the line both sides of the provenance check compare.
     *
     * Rounded to the whole minute. Timefold answers with seconds - 08:17:21 -
     * and Salesforce stores SchedStartTime to the minute, so without rounding
     * a signature never matches what the org holds, and every scheduled
     * appointment looks hand-made.
     */
    public static String placementOf(Id visitId, Id resourceId,
                                     Datetime startsAt) {
        if (visitId == null || resourceId == null || startsAt == null) {
            return null;
        }
        return visitId + '|' + resourceId + '|' + (startsAt.getTime() / 60000);
    }

    private static Set<String> splitOn(String raw) {
        Set<String> out = new Set<String>();
        for (String piece : (raw == null ? '' : raw).split(';')) {
            if (String.isNotBlank(piece)) {
                out.add(piece.trim());
            }
        }
        return out;
    }

    private static Integer seconds(Time value) {
        return value == null
            ? 0
            : value.hour() * 3600 + value.minute() * 60 + value.second();
    }
}
