/**
 * Step one of the roster: what does Salesforce know?
 *
 * Plain SOQL against standard Field Service objects, into typed inner classes.
 * No business logic lives here - it reads, and nothing else - which is what
 * makes the translate step readable.
 *
 * The queries are deliberately simple: no child sub-queries, no GROUP BY, no
 * relative date literals. That keeps every query inside a governor limit that
 * is easy to reason about.
 */
public with sharing class TimefoldRosterExtract {

    /** A nurse, and what they are allowed and able to do. */
    public class Nurse {
        public Id recordId;
        public String name;
        public Map<String, Decimal> skills = new Map<String, Decimal>();
        public List<String> wards = new List<String>();      // primary first
        public Id operatingHoursId;
        public Decimal capacityHoursPerMonth;
    }

    /** A shift that needs somebody on it. */
    public class ShiftDemand {
        public Id recordId;
        public String label;
        public Datetime startAt;
        public Datetime endAt;
        public String ward;
        public String role;                                   // JobProfile.Name
        public String status;
        public Id assignedResourceId;

        /**
         * Day, Evening or Night, taken from the label's last word.
         *
         * Salesforce has no field for this. The seed data names shifts "ICU
         * Night" and so on, and the rule that limits how many shift types a
         * nurse works in a week needs the distinction.
         */
        public String shiftType() {
            if (String.isBlank(label)) {
                return 'Shift';
            }
            List<String> parts = label.trim().split('\\s+');
            return parts[parts.size() - 1];
        }
    }

    public class Absence {
        public Id resourceId;
        public String kind;
        public Datetime startAt;
        public Datetime endAt;
    }

    /** One row of an OperatingHours pattern. */
    public class DailyWindow {
        public String dayOfWeek;
        public Integer startSeconds;
        public Integer endSeconds;
        public Boolean wrapsMidnight = false;
    }

    /** Everything one roster run needs. */
    public class Problem {
        public List<Nurse> nurses = new List<Nurse>();
        public List<ShiftDemand> shifts = new List<ShiftDemand>();
        public List<Absence> absences = new List<Absence>();
        public Map<Id, List<DailyWindow>> operatingHours = new Map<Id, List<DailyWindow>>();
        public Datetime windowStart;
        public Datetime windowEnd;

        public Nurse nurseById(Id resourceId) {
            for (Nurse n : nurses) {
                if (n.recordId == resourceId) {
                    return n;
                }
            }
            return null;
        }
    }

    /**
     * Read the roster problem.
     *
     * The window starts at the earliest unassigned shift rather than at today,
     * because a demo org seeded last week should still have something to plan.
     * If every shift is assigned it starts at the earliest shift of all, so a
     * re-plan is possible.
     */
    public static Problem run(Integer days) {
        Problem problem = new Problem();

        Datetime earliest = earliestShiftStart();
        if (earliest == null) {
            throw new TimefoldClient.TimefoldException(
                'There are no Shift records to plan. Seed the demo data first: '
                + 'sf apex run --file scripts/apex/seed.apex');
        }
        // Start at midnight UTC of that day, so week boundaries line up with
        // the weekStart the model is told about.
        problem.windowStart = Datetime.newInstanceGmt(
            earliest.dateGmt(), Time.newInstance(0, 0, 0, 0));
        problem.windowEnd = problem.windowStart.addDays(days);

        loadShifts(problem);
        loadNurses(problem);
        loadAbsences(problem);
        loadOperatingHours(problem);
        return problem;
    }

    private static Datetime earliestShiftStart() {
        List<Shift> unassigned = [
            SELECT StartTime FROM Shift
            WHERE ServiceResourceId = NULL
            ORDER BY StartTime ASC LIMIT 1];
        if (!unassigned.isEmpty()) {
            return unassigned[0].StartTime;
        }
        List<Shift> anyShift = [SELECT StartTime FROM Shift ORDER BY StartTime ASC LIMIT 1];
        return anyShift.isEmpty() ? null : anyShift[0].StartTime;
    }

    private static void loadShifts(Problem problem) {
        for (Shift row : [
                SELECT Id, Label, StartTime, EndTime, Status, ServiceResourceId,
                       ServiceTerritory.Name, JobProfile.Name
                FROM Shift
                WHERE StartTime >= :problem.windowStart
                  AND StartTime < :problem.windowEnd
                ORDER BY StartTime ASC
                LIMIT 5000]) {
            ShiftDemand demand = new ShiftDemand();
            demand.recordId = row.Id;
            demand.label = row.Label;
            demand.startAt = row.StartTime;
            demand.endAt = row.EndTime;
            demand.status = row.Status;
            demand.assignedResourceId = row.ServiceResourceId;
            demand.ward = row.ServiceTerritory.Name;
            demand.role = row.JobProfile.Name;
            problem.shifts.add(demand);
        }
    }

    private static void loadNurses(Problem problem) {
        Map<Id, Nurse> byId = new Map<Id, Nurse>();
        for (ServiceResource row : [
                SELECT Id, Name FROM ServiceResource
                WHERE IsActive = TRUE ORDER BY Name ASC LIMIT 2000]) {
            Nurse nurse = new Nurse();
            nurse.recordId = row.Id;
            nurse.name = row.Name;
            byId.put(row.Id, nurse);
        }

        // Territory membership is what makes a nurse eligible for a ward. The
        // primary membership comes first, because it is also the fallback for
        // anything that needs a single home ward.
        for (ServiceTerritoryMember row : [
                SELECT ServiceResourceId, TerritoryType, OperatingHoursId,
                       ServiceTerritory.Name
                FROM ServiceTerritoryMember
                ORDER BY TerritoryType ASC LIMIT 5000]) {
            Nurse nurse = byId.get(row.ServiceResourceId);
            if (nurse == null || String.isBlank(row.ServiceTerritory.Name)) {
                continue;
            }
            if (row.TerritoryType == 'P') {
                // Primary first. Apex refuses List.add(0, x) on an empty list,
                // so the empty case has to be the plain add.
                if (nurse.wards.isEmpty()) {
                    nurse.wards.add(row.ServiceTerritory.Name);
                } else {
                    nurse.wards.add(0, row.ServiceTerritory.Name);
                }
                nurse.operatingHoursId = row.OperatingHoursId;
            } else if (!nurse.wards.contains(row.ServiceTerritory.Name)) {
                nurse.wards.add(row.ServiceTerritory.Name);
            }
        }

        for (ServiceResourceSkill row : [
                SELECT ServiceResourceId, SkillLevel, Skill.MasterLabel
                FROM ServiceResourceSkill LIMIT 5000]) {
            Nurse nurse = byId.get(row.ServiceResourceId);
            if (nurse != null && String.isNotBlank(row.Skill.MasterLabel)) {
                nurse.skills.put(row.Skill.MasterLabel,
                                 row.SkillLevel == null ? 0 : row.SkillLevel);
            }
        }

        // Contract hours. ServiceResourceCapacity.TimePeriod offers no Weeks,
        // so 40 hours a week is stored as 173 a month and converted back here.
        // Get that wrong and every contract is quietly 8% off.
        for (ServiceResourceCapacity row : [
                SELECT ServiceResourceId, CapacityInHours, TimePeriod
                FROM ServiceResourceCapacity LIMIT 2000]) {
            Nurse nurse = byId.get(row.ServiceResourceId);
            if (nurse == null || row.CapacityInHours == null) {
                continue;
            }
            nurse.capacityHoursPerMonth = toMonthlyHours(row.CapacityInHours,
                                                         row.TimePeriod);
        }

        problem.nurses = byId.values();
    }

    /** Normalise whatever TimePeriod the org accepted into hours per month. */
    @TestVisible
    private static Decimal toMonthlyHours(Decimal hours, String period) {
        if (hours == null) {
            return null;
        }
        // The picklist differs between orgs: Day/Week/Month in one, and
        // Days/Hours/Months in another. Both spellings are read, because the
        // alternative is contract hours that are quietly out by a factor of
        // four and a roster that looks plausible.
        String unit = period == null ? 'Month' : period;
        if (unit == 'Month' || unit == 'Months') {
            return hours;
        }
        if (unit == 'Week' || unit == 'Weeks') {
            return (hours * 52 / 12).setScale(2);
        }
        if (unit == 'Day' || unit == 'Days') {
            return (hours * 365 / 12).setScale(2);
        }
        if (unit == 'Hour' || unit == 'Hours') {
            // Hours per hour is not a contract; treat it as a monthly figure
            // rather than inventing a conversion.
            return hours;
        }
        return hours;
    }

    private static void loadAbsences(Problem problem) {
        for (ResourceAbsence row : [
                SELECT ResourceId, Type, Start, End FROM ResourceAbsence
                WHERE End >= :problem.windowStart
                  AND Start < :problem.windowEnd
                LIMIT 2000]) {
            Absence absence = new Absence();
            absence.resourceId = row.ResourceId;
            absence.kind = row.Type;
            absence.startAt = row.Start;
            absence.endAt = row.End;
            problem.absences.add(absence);
        }
    }

    private static void loadOperatingHours(Problem problem) {
        for (TimeSlot row : [
                SELECT OperatingHoursId, DayOfWeek, StartTime, EndTime
                FROM TimeSlot LIMIT 5000]) {
            DailyWindow window = new DailyWindow();
            window.dayOfWeek = row.DayOfWeek;
            window.startSeconds = seconds(row.StartTime);
            window.endSeconds = seconds(row.EndTime);
            // A Salesforce TimeSlot cannot cross midnight, so a night rota is
            // stored as 23:00-23:59:59 plus 00:00-07:00 the next day. The
            // translate step joins the two back together.
            window.wrapsMidnight = window.endSeconds <= window.startSeconds;
            if (!problem.operatingHours.containsKey(row.OperatingHoursId)) {
                problem.operatingHours.put(row.OperatingHoursId,
                                           new List<DailyWindow>());
            }
            problem.operatingHours.get(row.OperatingHoursId).add(window);
        }
    }

    private static Integer seconds(Time value) {
        return value == null
            ? 0
            : value.hour() * 3600 + value.minute() * 60 + value.second();
    }
}
