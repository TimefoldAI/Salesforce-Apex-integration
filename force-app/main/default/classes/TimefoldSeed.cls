/**
 * The demo hospital, created in Apex.
 *
 * It builds a nurse roster and a field service round directly with DML, so
 * there are no data files to load.
 *
 * Idempotent. Run it twice and nothing doubles.
 *
 * The awkward parts are all constraints of the platform, and each one is
 * marked below. In short:
 *
 *   - Skill and ServiceResource cannot be deleted, whatever permissions you
 *     hold, so both are reused rather than recreated.
 *   - A ServiceResource must point at a User or a ServiceCrew, and a Developer
 *     Edition org has about five user licences, not fifty. The roster is
 *     therefore sized to the org rather than to the scenario.
 *   - A TimeSlot cannot cross midnight, so the night rota is two rows.
 *   - Salesforce refuses to put a resource on a Shift unless they are a member
 *     of that territory, so memberships come before shifts.
 *   - A capacity-based resource gets no appointment bars in the dispatcher
 *     console, so IsCapacityBased is set on the nurses only, never on every
 *     technician in the org.
 */
public with sharing class TimefoldSeed {

    /** Wards, and how many nurses each needs on a day shift. */
    private static final List<String> WARDS = new List<String>{
        'St. Elmore ICU', 'St. Elmore Emergency', 'St. Elmore General Medicine'
    };

    /** Certificates, as Skill records. DeveloperName is the natural key. */
    private static final Map<String, String> SKILLS = new Map<String, String>{
        'ICU_Certification'             => 'ICU Certification',
        'Ventilator_Management'         => 'Ventilator Management',
        'Triage'                        => 'Triage',
        'Advanced_Cardiac_Life_Support' => 'Advanced Cardiac Life Support',
        'Charge_Nurse'                  => 'Charge Nurse',
        'Medication_Administration'     => 'Medication Administration'
    };

    /** Roles, as JobProfile records. These drive the required skills. */
    private static final List<String> ROLES = new List<String>{
        'ICU Registered Nurse', 'Emergency Nurse', 'Charge Nurse',
        'Registered Nurse'
    };

    /**
     * Which role a ward's shifts are staffed by, and so which certificates
     * they demand: TimefoldRules.roleSkills() turns the role into skills, and
     * TimefoldRosterRequest puts those on the shift as requiredSkills.
     *
     * Two things read this and they have to agree. A ward whose shifts demand
     * Triage, staffed by nurses who hold anything else, is a roster with no
     * legal answer - and the solver's answer to that is to assign nobody,
     * because an unassigned shift costs one medium point and a nurse without
     * the certificate costs a hard one.
     */
    private static final Map<String, String> ROLE_FOR_WARD = new Map<String, String>{
        'St. Elmore ICU'              => 'ICU Registered Nurse',
        'St. Elmore Emergency'        => 'Emergency Nurse',
        'St. Elmore General Medicine' => 'Registered Nurse'
    };

    /** What each nurse is certified for, cycled across however many exist. */
    private static final List<List<String>> SKILL_SETS = new List<List<String>>{
        new List<String>{ 'ICU Certification', 'Ventilator Management',
                          'Medication Administration' },
        new List<String>{ 'Triage', 'Advanced Cardiac Life Support',
                          'Medication Administration' },
        new List<String>{ 'Charge Nurse', 'Medication Administration',
                          'ICU Certification' },
        new List<String>{ 'Medication Administration', 'Triage' },
        new List<String>{ 'ICU Certification', 'Ventilator Management',
                          'Charge Nurse', 'Medication Administration' },
        new List<String>{ 'Medication Administration',
                          'Advanced Cardiac Life Support' }
    };

    public class Report {
        public Integer nurses = 0;
        public Integer renamed = 0;
        public Integer wards = 0;
        public Integer shifts = 0;
        public Integer skills = 0;
        public Integer absences = 0;
        public Integer days = 0;
        public Integer regions = 0;
        public Integer engineers = 0;
        public Integer visits = 0;
        public String note = '';

        public override String toString() {
            return 'Seeded ' + wards + ' wards, ' + nurses + ' nurses, '
                 + skills + ' skills, ' + absences + ' absences and '
                 + shifts + ' shifts across ' + days + ' days. '
                 + 'Field service: ' + regions + ' regions, ' + engineers
                 + ' engineers, ' + visits + ' visits. '
                 + (renamed > 0
                    ? 'Renamed ' + renamed + ' resource(s) after their user. '
                    : '')
                 + note;
        }
    }

    /** Seed with the default horizon. */
    public static Report run() {
        return run(TimefoldRules.count('Roster.PlanningDays'));
    }

    public static Report run(Integer days) {
        Report report = new Report();
        report.days = days;

        Map<String, Id> skillIds = ensureSkills(report);
        Map<String, Id> roleIds = ensureRoles();
        Id dayHours = ensureOperatingHours('St. Elmore 08:00-20:00', false);
        Id nightHours = ensureOperatingHours('St. Elmore nights', true);
        Map<String, Id> wardIds = ensureWards(dayHours, report);
        // Before anything else reads them: a resource is named after its User.
        report.renamed = renameAfterUsers();
        List<ServiceResource> nurses = ensureNurses(report, wardIds);

        if (nurses.isEmpty()) {
            // Not fatal: the two halves of the demo are independent, so the
            // field service round is still seeded.
            report.note = 'No nurse could be created: a ServiceResource needs a '
                + 'User and this org has no spare licence, so the rota was not '
                + 'seeded. Run scripts/apex/users.apex first to create demo '
                + 'users from whatever licences the org has. ';
        } else {
            ensureMemberships(nurses, wardIds, dayHours, nightHours);
            ensureSkillAssignments(nurses, skillIds);
            ensureCapacities(nurses);
            report.absences = ensureAbsences(nurses);
            report.shifts = ensureShifts(wardIds, roleIds, days, nurses.size());
        }

        // The other half of the demo: the London field service round, which
        // the routing model plans. Separate data, same org, and deliberately
        // no overlap with the hospital - the two integrations have to be able
        // to share an org without touching each other's records.
        ensureFieldService(report);

        // The rules the integration reads, as editable rows. TimefoldRules has
        // the same values built in, so this only makes them visible.
        report.note += 'Settings: ' + ensureSettings() + ' rows.';

        markRecentlyViewed();
        return report;
    }

    // ------------------------------------------------------------------ skills

    /**
     * Read the Skill records, which this class cannot create.
     *
     * Skill reports createable=true and the REST API can insert one, but
     * Apex DML refuses: "DML operation Insert not allowed on List<Skill>". It
     * is a setup object, so it is deployed as metadata instead, from
     * force-app/main/default/skills.
     *
     * That is the better home anyway. Skill is also deletable=false in every
     * org, and MasterLabel is what the integration matches on, so renaming one
     * silently re-points every assignment that referenced the old name.
     */
    private static Map<String, Id> ensureSkills(Report report) {
        Map<String, Id> byDeveloperName = new Map<String, Id>();
        for (Skill existing : [
                SELECT Id, DeveloperName FROM Skill
                WHERE DeveloperName IN :SKILLS.keySet()]) {
            byDeveloperName.put(existing.DeveloperName, existing.Id);
        }
        if (byDeveloperName.size() < SKILLS.size()) {
            Set<String> absent = new Set<String>(SKILLS.keySet());
            absent.removeAll(byDeveloperName.keySet());
            report.note = 'Missing Skill records: '
                + String.join(new List<String>(absent), ', ')
                + '. Deploy them with: sf project deploy start --source-dir '
                + 'force-app/main/default/skills. ';
        }
        report.skills = byDeveloperName.size();

        // The integration matches on MasterLabel, so index by that too.
        Map<String, Id> byLabel = new Map<String, Id>();
        for (String developerName : byDeveloperName.keySet()) {
            byLabel.put(SKILLS.get(developerName),
                        byDeveloperName.get(developerName));
        }
        return byLabel;
    }

    private static Map<String, Id> ensureRoles() {
        Map<String, Id> byName = new Map<String, Id>();
        for (JobProfile existing : [
                SELECT Id, Name FROM JobProfile WHERE Name IN :ROLES]) {
            byName.put(existing.Name, existing.Id);
        }
        List<JobProfile> missing = new List<JobProfile>();
        for (String role : ROLES) {
            if (!byName.containsKey(role)) {
                missing.add(new JobProfile(Name = role));
            }
        }
        if (!missing.isEmpty()) {
            insert missing;
            for (JobProfile created : missing) {
                byName.put(created.Name, created.Id);
            }
        }
        return byName;
    }

    // ---------------------------------------------------------------- calendar

    /**
     * One OperatingHours pattern, with its TimeSlots.
     *
     * A TimeSlot cannot cross midnight - Salesforce rejects it with
     * "Start time must be before end time" - so the night pattern is a late
     * slot and an early slot on each day, and TimefoldRosterRequest joins them
     * back together before telling Timefold when a nurse is available.
     */
    private static Id ensureOperatingHours(String name, Boolean nights) {
        List<OperatingHours> existing = [
            SELECT Id FROM OperatingHours WHERE Name = :name LIMIT 1];
        if (!existing.isEmpty()) {
            return existing[0].Id;
        }
        OperatingHours hours = new OperatingHours(
            Name = name, TimeZone = 'Europe/London',
            Description = nights ? 'Night cover, 23:00 to 07:00.'
                                 : 'Day and evening cover.');
        insert hours;

        List<TimeSlot> slots = new List<TimeSlot>();
        for (String day : new List<String>{
                'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday',
                'Saturday', 'Sunday' }) {
            if (nights) {
                slots.add(new TimeSlot(
                    OperatingHoursId = hours.Id, DayOfWeek = day, Type = 'Normal',
                    StartTime = Time.newInstance(23, 0, 0, 0),
                    EndTime = Time.newInstance(23, 59, 59, 0)));
                slots.add(new TimeSlot(
                    OperatingHoursId = hours.Id, DayOfWeek = day, Type = 'Normal',
                    StartTime = Time.newInstance(0, 0, 0, 0),
                    EndTime = Time.newInstance(7, 0, 0, 0)));
            } else {
                slots.add(new TimeSlot(
                    OperatingHoursId = hours.Id, DayOfWeek = day, Type = 'Normal',
                    StartTime = Time.newInstance(7, 0, 0, 0),
                    EndTime = Time.newInstance(23, 0, 0, 0)));
            }
        }
        insert slots;
        return hours.Id;
    }

    private static Map<String, Id> ensureWards(Id dayHours, Report report) {
        Map<String, Id> byName = new Map<String, Id>();
        for (ServiceTerritory existing : [
                SELECT Id, Name FROM ServiceTerritory WHERE Name IN :WARDS]) {
            byName.put(existing.Name, existing.Id);
        }
        List<ServiceTerritory> missing = new List<ServiceTerritory>();
        for (String ward : WARDS) {
            if (!byName.containsKey(ward)) {
                missing.add(new ServiceTerritory(
                    Name = ward, OperatingHoursId = dayHours, IsActive = true,
                    // No address text on purpose. The Geocodes data
                    // integration rules re-geocode anything carrying one, and
                    // "London" resolves to a single point, so every ward would
                    // land on the same pin.
                    Latitude = 51.5072, Longitude = -0.1276,
                    Description = ward + ' ward.'));
            }
        }
        if (!missing.isEmpty()) {
            insert missing;
            for (ServiceTerritory created : missing) {
                byName.put(created.Name, created.Id);
            }
        }
        report.wards = byName.size();
        return byName;
    }

    // ----------------------------------------------------------------- nurses

    /**
     * As many nurses as the org can hold.
     *
     * A ServiceResource must point at a User or a ServiceCrew. Crews look like
     * the way round the licence limit, until a crew turns out to need active
     * members, which are themselves resources. So these are User-backed, one
     * per user, and the roster is sized to the org: a Developer Edition org
     * gives about five nurses, not forty-seven.
     */
    private static List<ServiceResource> ensureNurses(Report report,
                                                     Map<String, Id> wardIds) {
        // Every technician in the org, so a User already backing one is not
        // claimed twice. Not all of them are nurses: another demo may share
        // this org, and its people must be left exactly as they are.
        List<ServiceResource> existing = [
            SELECT Id, Name, RelatedRecordId FROM ServiceResource
            WHERE IsActive = TRUE AND ResourceType = 'T'
            ORDER BY Name ASC LIMIT 200];
        Set<Id> taken = new Set<Id>();
        for (ServiceResource resource : existing) {
            taken.add(resource.RelatedRecordId);
        }

        // A nurse is a resource who works a ward. That is the only marker
        // needed, and it is the org's own data rather than a convention.
        Set<Id> nurseIds = wardMembers(wardIds);

        List<User> spare = preferring([
            SELECT Id, Name FROM User
            WHERE IsActive = TRUE AND Id NOT IN :taken
              AND Profile.UserLicense.Name IN ('Salesforce', 'Salesforce Platform')
            ORDER BY CreatedDate ASC LIMIT 50], NAMES);

        // Leave some for the engineers. A Developer Edition or scratch org has
        // four or five usable licences in total, and the rota is seeded first,
        // so without this the nurses take every one and the field service
        // round is left with nobody to route: two regions, no engineers, no
        // visits. Whoever has the most already keeps it - this only ever
        // limits what is created now.
        Integer reserve = TimefoldRules.count('Seed.ReserveForEngineers');
        Integer engineersAlready = [
            SELECT COUNT() FROM ServiceTerritoryMember
            WHERE ServiceTerritory.Name = :FS_REGION];
        Integer keepBack = Math.max(0, reserve - engineersAlready);
        Integer allowed = Math.max(0, spare.size() - keepBack);

        List<ServiceResource> created = new List<ServiceResource>();
        for (User user : spare) {
            if (created.size() >= allowed) {
                break;
            }
            created.add(new ServiceResource(
                // The user's own name, not a name from a list. See preferring().
                Name = user.Name,
                ResourceType = 'T', IsActive = true,
                RelatedRecordId = user.Id,
                // Without this, every ServiceResourceCapacity insert is
                // rejected with "You can only define a Service Resource's
                // capacity if the Capacity-Based option is selected" - and
                // with a partial-success insert that rejection is silent, so
                // the nurses end up with no contract hours at all.
                IsCapacityBased = true,
                Description = NURSE_MARK));
        }
        if (!created.isEmpty()) {
            // Partial success: one refusal - a licence that is not usable -
            // should not cost the others.
            Database.insert(created, false);
        }

        for (ServiceResource resource : created) {
            if (resource.Id != null) {
                nurseIds.add(resource.Id);
            }
        }

        List<ServiceResource> all = [
            SELECT Id, Name, IsCapacityBased FROM ServiceResource
            WHERE Id IN :nurseIds AND IsActive = TRUE
            ORDER BY Name ASC LIMIT 200];

        // A nurse that is not capacity-based has every contract-hours row
        // rejected without an error.
        //
        // Only the nurses. The Field Service dispatcher console draws no
        // appointment bars on a capacity-based resource's row, so setting
        // IsCapacityBased on other resources would empty their Gantt rows.
        List<ServiceResource> toFix = new List<ServiceResource>();
        for (ServiceResource resource : all) {
            if (resource.IsCapacityBased != true) {
                toFix.add(new ServiceResource(Id = resource.Id,
                                              IsCapacityBased = true));
            }
        }
        if (!toFix.isEmpty()) {
            Database.update(toFix, false);
        }

        report.nurses = all.size();
        return all;
    }

    /** The resources already working one of the wards. */
    private static Set<Id> wardMembers(Map<String, Id> wardIds) {
        Set<Id> found = new Set<Id>();
        if (wardIds == null || wardIds.isEmpty()) {
            return found;
        }
        Set<Id> territories = new Set<Id>(wardIds.values());
        for (ServiceTerritoryMember row : [
                SELECT ServiceResourceId FROM ServiceTerritoryMember
                WHERE ServiceTerritoryId IN :territories
                  AND ServiceResource.IsActive = TRUE LIMIT 2000]) {
            found.add(row.ServiceResourceId);
        }
        return found;
    }

    /**
     * Who the rota is about, in the order the ward would fill.
     *
     * A spare user called Bethan Rees becomes a nurse before one called
     * anything else, and the resource is called Bethan Rees because that is
     * who is behind it.
     */
    private static final List<String> NAMES = new List<String>{
        'Amara Okafor', 'Bethan Rees', 'Chidi Nwosu', 'Dara Kelly',
        'Elena Petrova', 'Farida Hassan', 'Grace Mwangi', 'Hana Yilmaz',
        'Ines Duarte', 'Jonas Berg'
    };

    private static final String NURSE_MARK = 'Nurse seeded by TimefoldSeed.';

    /**
     * Spare users, the ones this half of the demo is named after first.
     *
     * A ServiceResource is a person, and every list view shows its Name next
     * to its User. Those two have to be the same person. They were not: the
     * names came from a list by position while the users were claimed in
     * CreatedDate order, so the org ended up with a nurse called Chidi Nwosu
     * whose login was Amara Okafor's, and a resource called Amara Okafor that
     * was really the administrator. Nothing was broken - the plan is built
     * from ids - and it reads as though everything is.
     *
     * The name comes from the User now, so the two cannot disagree. The pool
     * only decides which spare user is taken first. Anybody not in it goes to
     * the back rather than being left out: an org without the licences for a
     * Nadia Rahimi still gets a second engineer, and that engineer is called
     * whatever their user is called, which is the truth about them.
     */
    private static List<User> preferring(List<User> spare, List<String> pool) {
        Map<String, User> byName = new Map<String, User>();
        for (User user : spare) {
            if (!byName.containsKey(user.Name)) {
                byName.put(user.Name, user);
            }
        }
        List<User> ordered = new List<User>();
        Set<Id> placed = new Set<Id>();
        for (String name : pool) {
            User match = byName.get(name);
            if (match != null && !placed.contains(match.Id)) {
                ordered.add(match);
                placed.add(match.Id);
            }
        }
        for (User user : spare) {
            if (!placed.contains(user.Id)) {
                ordered.add(user);
            }
        }
        return ordered;
    }

    /**
     * Repair the orgs that were seeded before the above was true.
     *
     * Only this seeder's own resources, which the Description marks. Renaming
     * a ServiceResource that belongs to somebody else's demo would be a
     * surprise in an org that hosts more than this one, and the whole point of
     * the markers is that this seeder knows which records are its own.
     */
    private static Integer renameAfterUsers() {
        // The marker is sorted in Apex rather than in the WHERE clause:
        // Description is a long text area, and SOQL answers a filter on one
        // with "field 'Description' can not be filtered in a query call".
        Set<String> mine = new Set<String>{ NURSE_MARK, ENGINEER_MARK };
        List<ServiceResource> wrong = new List<ServiceResource>();
        for (ServiceResource resource : [
                SELECT Id, Name, Description, RelatedRecord.Name
                FROM ServiceResource
                WHERE RelatedRecordId != NULL AND IsActive = TRUE
                LIMIT 500]) {
            if (mine.contains(resource.Description)
                    && resource.RelatedRecord.Name != null
                    && resource.Name != resource.RelatedRecord.Name) {
                wrong.add(new ServiceResource(
                    Id = resource.Id, Name = resource.RelatedRecord.Name));
            }
        }
        if (wrong.isEmpty()) {
            return 0;
        }
        Integer fixed = 0;
        for (Database.SaveResult saved : Database.update(wrong, false)) {
            if (saved.isSuccess()) {
                fixed++;
            }
        }
        return fixed;
    }

    /**
     * Ward membership, which is both eligibility and calendar.
     *
     * The primary membership carries the operating hours, which is how a
     * night-only nurse is expressed: every third nurse gets the night pattern.
     */
    private static void ensureMemberships(List<ServiceResource> nurses,
                                          Map<String, Id> wardIds,
                                          Id dayHours, Id nightHours) {
        // Per nurse and ward rather than per nurse: an org seeded before the
        // secondary rows worked has the primary one and is missing the float,
        // and "this nurse has a membership already" would leave it that way
        // for ever.
        Set<String> alreadyMember = new Set<String>();
        for (ServiceTerritoryMember existing : [
                SELECT ServiceResourceId, ServiceTerritoryId
                FROM ServiceTerritoryMember
                WHERE ServiceResourceId IN :nurses]) {
            alreadyMember.add(existing.ServiceResourceId + '|'
                              + existing.ServiceTerritoryId);
        }

        List<String> wardNames = new List<String>(wardIds.keySet());
        wardNames.sort();
        List<ServiceTerritoryMember> members = new List<ServiceTerritoryMember>();
        Datetime memberFrom = Datetime.now().addDays(-30);

        for (Integer i = 0; i < nurses.size(); i++) {
            String home = wardNames[Math.mod(i, wardNames.size())];
            if (!alreadyMember.contains(nurses[i].Id + '|' + wardIds.get(home))) {
                members.add(new ServiceTerritoryMember(
                    ServiceResourceId = nurses[i].Id,
                    ServiceTerritoryId = wardIds.get(home),
                    TerritoryType = 'P',
                    OperatingHoursId = Math.mod(i, 3) == 2 ? nightHours : dayHours,
                    EffectiveStartDate = memberFrom,
                    Latitude = 51.5072, Longitude = -0.1276));
            }
            // A second ward, so somebody can float. Secondary memberships
            // cannot overlap a primary one for the same period, so this uses
            // the next ward along rather than the same one.
            //
            // And it carries no operating hours and no coordinates, because
            // Salesforce refuses one that does:
            //
            //   FIELD_CUSTOM_VALIDATION_EXCEPTION: Cannot save Service
            //   Territory Member of type secondary with Operating Hours or
            //   Address
            //
            // The insert is partial-success, so that rejection would be
            // silent. A secondary member keeps the calendar of their primary
            // ward, which is Salesforce's model - a night nurse floats to
            // night work only.
            String floatTo = wardNames[Math.mod(i + 1, wardNames.size())];
            if (!alreadyMember.contains(nurses[i].Id + '|' + wardIds.get(floatTo))) {
                members.add(new ServiceTerritoryMember(
                    ServiceResourceId = nurses[i].Id,
                    ServiceTerritoryId = wardIds.get(floatTo),
                    TerritoryType = 'S',
                    EffectiveStartDate = memberFrom));
            }
        }
        if (!members.isEmpty()) {
            Database.insert(members, false);
        }
    }

    /**
     * Certificates, and the ward decides them.
     *
     * SKILL_SETS alone does not: a nurse without the skills their ward's
     * shifts demand cannot be assigned, and a ward nobody can work leaves
     * every shift unassigned.
     *
     * So each nurse is given what their wards demand, from the same
     * TimefoldRules.roleSkills() the request builder reads when it writes
     * requiredSkills onto the shift. Both wards, primary and secondary, so a
     * float is qualified where they float to. SKILL_SETS stays on top of that
     * for variety - a rota where everyone holds exactly the minimum is not a
     * rota anybody has to think about.
     */
    private static void ensureSkillAssignments(List<ServiceResource> nurses,
                                               Map<String, Id> skillIds) {
        Set<String> existing = new Set<String>();
        for (ServiceResourceSkill row : [
                SELECT ServiceResourceId, SkillId FROM ServiceResourceSkill
                WHERE ServiceResourceId IN :nurses]) {
            existing.add(row.ServiceResourceId + '|' + row.SkillId);
        }

        Map<String, List<String>> roleSkills = TimefoldRules.roleSkills();
        Map<Id, Set<String>> wardDemands = new Map<Id, Set<String>>();
        for (ServiceTerritoryMember row : [
                SELECT ServiceResourceId, ServiceTerritory.Name
                FROM ServiceTerritoryMember
                WHERE ServiceResourceId IN :nurses LIMIT 2000]) {
            String role = ROLE_FOR_WARD.get(row.ServiceTerritory.Name);
            if (role == null || !roleSkills.containsKey(role)) {
                continue;                       // not one of the demo's wards
            }
            if (!wardDemands.containsKey(row.ServiceResourceId)) {
                wardDemands.put(row.ServiceResourceId, new Set<String>());
            }
            wardDemands.get(row.ServiceResourceId).addAll(roleSkills.get(role));
        }

        List<ServiceResourceSkill> rows = new List<ServiceResourceSkill>();
        Date skillFrom = Date.today().addDays(-30);
        for (Integer i = 0; i < nurses.size(); i++) {
            Set<String> give =
                new Set<String>(SKILL_SETS[Math.mod(i, SKILL_SETS.size())]);
            if (wardDemands.containsKey(nurses[i].Id)) {
                give.addAll(wardDemands.get(nurses[i].Id));
            }
            List<String> ordered = new List<String>(give);
            ordered.sort();
            for (String skill : ordered) {
                Id skillId = skillIds.get(skill);
                if (skillId == null
                        || existing.contains(nurses[i].Id + '|' + skillId)) {
                    continue;
                }
                rows.add(new ServiceResourceSkill(
                    ServiceResourceId = nurses[i].Id, SkillId = skillId,
                    SkillLevel = 7, EffectiveStartDate = skillFrom));
            }
        }
        if (!rows.isEmpty()) {
            Database.insert(rows, false);
        }
    }

    /**
     * Contract hours.
     *
     * ServiceResourceCapacity.TimePeriod offers no Weeks, so a 40-hour week is
     * stored as 173 hours a month and converted back on the way out. The
     * managed package, if installed, also insists the record spans exactly one
     * TimePeriod and rejects an empty EndDate, so both are set.
     */
    private static void ensureCapacities(List<ServiceResource> nurses) {
        Set<Id> already = new Set<Id>();
        for (ServiceResourceCapacity row : [
                SELECT ServiceResourceId FROM ServiceResourceCapacity
                WHERE ServiceResourceId IN :nurses]) {
            already.add(row.ServiceResourceId);
        }
        List<ServiceResourceCapacity> rows = new List<ServiceResourceCapacity>();
        for (Integer i = 0; i < nurses.size(); i++) {
            if (already.contains(nurses[i].Id)) {
                continue;
            }
            // Full time and part time, so the roster has more than one contract
            // and the rule ids have to be scoped by contract.
            rows.add(capacityFor(nurses[i].Id, Math.mod(i, 4) == 3 ? 104 : 173));
        }
        if (!rows.isEmpty()) {
            Database.insert(rows, false);
        }
    }

    /**
     * One capacity row, in whatever unit this org's picklist offers.
     *
     * TimePeriod is a restricted picklist whose values differ between orgs.
     * This one offers Day, Week and Month; others offer Days, Hours and Months.
     * Writing a value it does not have fails with
     * INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST, and with a partial-success
     * insert that failure is silent: the nurses simply end up with no contract
     * hours, every contract collapses into one, and nothing looks wrong.
     *
     * So the picklist is described and the hours are rescaled to match. The
     * managed package, if installed, also insists the row spans exactly one
     * period and rejects an empty EndDate, so both are set from the unit.
     */
    @TestVisible
    private static ServiceResourceCapacity capacityFor(Id resourceId,
                                                       Decimal hoursPerMonth) {
        Set<String> allowed = new Set<String>();
        for (Schema.PicklistEntry entry : ServiceResourceCapacity.TimePeriod
                .getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                allowed.add(entry.getValue());
            }
        }

        String unit;
        Decimal hours;
        Date startOn;
        Date endOn;
        if (allowed.contains('Month') || allowed.contains('Months')) {
            unit = allowed.contains('Month') ? 'Month' : 'Months';
            hours = hoursPerMonth;
            startOn = Date.today().toStartOfMonth();
            endOn = startOn.addMonths(1).addDays(-1);
        } else if (allowed.contains('Week') || allowed.contains('Weeks')) {
            unit = allowed.contains('Week') ? 'Week' : 'Weeks';
            hours = (hoursPerMonth * 12 / 52).setScale(2);
            startOn = Date.today().toStartOfWeek();
            endOn = startOn.addDays(6);
        } else {
            unit = allowed.contains('Day') ? 'Day' : 'Days';
            hours = (hoursPerMonth * 12 / 365).setScale(2);
            startOn = Date.today();
            endOn = startOn;
        }

        return new ServiceResourceCapacity(
            ServiceResourceId = resourceId,
            CapacityInHours = hours,
            TimePeriod = unit,
            StartDate = startOn,
            EndDate = endOn);
    }

    /** Leave, so the roster has to work around somebody. */
    private static Integer ensureAbsences(List<ServiceResource> nurses) {
        if ([SELECT COUNT() FROM ResourceAbsence] > 0) {
            return [SELECT COUNT() FROM ResourceAbsence];
        }
        List<ResourceAbsence> rows = new List<ResourceAbsence>();
        Datetime absenceFrom = Datetime.newInstanceGmt(Date.today().addDays(3),
                                                Time.newInstance(0, 0, 0, 0));
        for (Integer i = 0; i < nurses.size(); i += 3) {
            rows.add(new ResourceAbsence(
                ResourceId = nurses[i].Id, Type = 'Vacation',
                Start = absenceFrom.addDays(i), End = absenceFrom.addDays(i + 2)));
        }
        if (!rows.isEmpty()) {
            Database.insert(rows, false);
        }
        return [SELECT COUNT() FROM ResourceAbsence];
    }

    /**
     * The shifts to fill.
     *
     * Sized to the staff, not to the scenario: raising more work than the
     * nurses can cover makes the solver leave shifts empty, and that reads as
     * a broken integration rather than as a staffing problem. Two thirds of
     * capacity leaves room for the rest and weekend rules to matter.
     */
    private static Integer ensureShifts(Map<String, Id> wardIds,
                                        Map<String, Id> roleIds,
                                        Integer days, Integer nurseCount) {
        if ([SELECT COUNT() FROM Shift] > 0) {
            return [SELECT COUNT() FROM Shift];
        }

        List<String> wardNames = new List<String>(wardIds.keySet());
        wardNames.sort();

        // A nurse can work about five of every seven days, and one shift a day.
        Integer perDay = Math.max(1, (Integer) ((nurseCount * 5.0 / 7.0) * 0.66));
        List<Shift> shifts = new List<Shift>();
        Date startOn = Date.today().toStartOfWeek().addDays(
            Date.today().toStartOfWeek() > Date.today() ? -7 : 0);

        // The ward and the day pattern cycle on a running count, not on the
        // inner one. Three nurses give perDay = 1, so the inner counter never
        // left zero: every shift in the fortnight went to the first ward
        // alphabetically and none was ever a night, while the memberships
        // handed a night calendar to every third nurse. The rota was fourteen
        // Emergency days for a ward with one nurse in it.
        //
        // Running, they line up: ward n takes shift n, and the third ward is
        // the night ward, which is the third nurse, who has the night
        // calendar. Each ward gets four or five shifts spread three days
        // apart, which no rest rule or consecutive-day rule objects to.
        Integer index = 0;
        for (Integer day = 0; day < days; day++) {
            Date onDate = startOn.addDays(day);
            for (Integer n = 0; n < perDay; n++) {
                String ward = wardNames[Math.mod(index, wardNames.size())];
                Boolean night = Math.mod(index, 3) == 2;
                Datetime shiftFrom = night
                    ? Datetime.newInstanceGmt(onDate, Time.newInstance(23, 0, 0, 0))
                    : Datetime.newInstanceGmt(onDate, Time.newInstance(7, 0, 0, 0));
                shifts.add(new Shift(
                    Label = ward.substringAfter('St. Elmore ').trim()
                            + (night ? ' Night' : ' Day'),
                    ServiceTerritoryId = wardIds.get(ward),
                    JobProfileId = roleIds.get(ROLE_FOR_WARD.get(ward)),
                    StartTime = shiftFrom,
                    EndTime = shiftFrom.addHours(8),
                    Status = 'Tentative'));
                index++;
            }
        }
        if (!shifts.isEmpty()) {
            Database.insert(shifts, false);
        }
        return [SELECT COUNT() FROM Shift];
    }

    /**
     * Write the rules out as records.
     *
     * TimefoldRules has every one of these built in, so this changes no
     * behaviour. It exists so an administrator can see what the integration is
     * using and change it in a list view, which is the whole point of having
     * the object.
     */
    private static Integer ensureSettings() {
        Map<String, String> notes = new Map<String, String>{
            'Roster.MinimumRestHours' =>
                'UK and EU working time rules put a full rest period at 11 hours.',
            'Roster.ContractHoursMinimumFraction' =>
                'A maximum alone does not spread work: leaving somebody idle costs '
                + 'nothing, so the solver is content to staff a ward with two people. '
                + 'This preferred floor is what makes an under-used nurse a penalty.',
            'Roster.WeekendWindowWeeks' =>
                'Two, for "at most one weekend in any two". A week only ever contains '
                + 'one weekend, so this cannot be expressed as a per-week rule: it '
                + 'would be valid, accepted, and have no effect at all.',
            'Roster.RespectExisting' =>
                'Pin shifts already staffed. A real deployment wants this on so a '
                + 'manual assignment survives a replan. Off here because after one '
                + 'run every shift is assigned, and a second run could change nothing.',
            'Weight.Routes.minimizeTravelDistanceWeight' =>
                'Zero on purpose. Timefold warns TRAVEL_WEIGHT_CONFLICT if both '
                + 'travel weights are non-zero, and the run still succeeds, so the '
                + 'warning is easy to ship without noticing.',
            'Weight.Routes.balanceTimeUtilizationWeight' =>
                'Travel time alone produces very lopsided days: one engineer takes '
                + 'every job in a tight cluster because it is cheap to drive, and '
                + 'another takes one. Balance has to outweigh travel.',
            'Routes.RootTerritory' =>
                'The territory the round covers. Everything under it is in scope, so '
                + 'one root name covers however many regions hang off it.',
            'Routes.RestrictToOwnRegion' =>
                'Sent as a required tag per visit. Turn it off to let Timefold move '
                + 'work across regional boundaries when that shortens the day.',
            'Routes.DefaultWorkDays' =>
                'Only used when a ServiceTerritoryMember has no OperatingHours. '
                + 'Without a day list the solver books a Sunday quite happily.',
            'Routes.OvertimeMinutes' =>
                'The rostered end is sent as a soft limit and this as the hard one, '
                + 'so an engineer runs late only when that beats leaving a job undone.',
            'Routes.BreaksFromAbsences' =>
                'ResourceAbsence becomes a FIXED break on the shift it falls in. Off, '
                + 'the solver drives straight through a break the Gantt is drawing.',
            'Routes.RespectExisting' =>
                'On, unlike the roster equivalent. A job a dispatcher has pinned, '
                + 'dispatched or scheduled by hand is not a planning decision any '
                + 'more, so the solver is told to leave it exactly where it is.',
            'Routes.PinnedStatusCategories' =>
                'Status categories that mean the job is already with an engineer. '
                + 'Standard values, not this integration\'s invention.'
        };

        Set<String> existing = new Set<String>();
        for (Timefold_Setting__c row : [SELECT Name FROM Timefold_Setting__c]) {
            existing.add(row.Name);
        }
        List<Timefold_Setting__c> rows = new List<Timefold_Setting__c>();
        for (String key : TimefoldRules.defaultKeys()) {
            if (existing.contains(key)) {
                continue;
            }
            rows.add(new Timefold_Setting__c(
                Name = key,
                Value__c = TimefoldRules.defaultFor(key),
                Category__c = categoryOf(key),
                Notes__c = notes.get(key)));
        }
        if (!rows.isEmpty()) {
            Database.insert(rows, false);
        }
        return [SELECT COUNT() FROM Timefold_Setting__c];
    }

    // -------------------------------------------------------- recently viewed

    /**
     * Make the seeded records show up on the tabs that list them.
     *
     * Every standard Field Service tab opens on **Recently Viewed**, which is
     * empty until somebody has opened a record - so a freshly seeded org shows
     * "Nothing to see here" on Work Orders, Service Resources and the rest,
     * with ten work orders sitting in the database. It reads exactly like a
     * seeder that did nothing, and it is the single most misleading thing
     * about a new org.
     *
     * SOQL's FOR VIEW is the supported way to say "treat these as viewed". It
     * affects only the running user, which is the person who just ran the
     * seeder and the one about to go looking.
     *
     * The list is not the whole of a plan - "All Work Orders" and the other
     * All views were always there - but the tab has to show something.
     */
    private static void markRecentlyViewed() {
        // Each is its own statement because FOR VIEW is part of the query, and
        // the results are deliberately unused.
        List<ServiceTerritory> territories =
            [SELECT Id FROM ServiceTerritory LIMIT 200 FOR VIEW];
        List<ServiceResource> resources =
            [SELECT Id FROM ServiceResource LIMIT 200 FOR VIEW];
        List<WorkOrder> orders =
            [SELECT Id FROM WorkOrder LIMIT 200 FOR VIEW];
        List<ServiceAppointment> appointments =
            [SELECT Id FROM ServiceAppointment LIMIT 200 FOR VIEW];
        List<Shift> shifts = [SELECT Id FROM Shift LIMIT 200 FOR VIEW];
        List<ResourceAbsence> absences =
            [SELECT Id FROM ResourceAbsence LIMIT 200 FOR VIEW];
        List<Timefold_Setting__c> settings =
            [SELECT Id FROM Timefold_Setting__c LIMIT 200 FOR VIEW];
        System.debug(LoggingLevel.DEBUG, 'Marked as viewed: '
            + territories.size() + ' territories, ' + resources.size()
            + ' resources, ' + orders.size() + ' orders, '
            + appointments.size() + ' appointments, ' + shifts.size()
            + ' shifts, ' + absences.size() + ' absences, '
            + settings.size() + ' settings.');
    }

    // ------------------------------------------------------------ demo users

    /**
     * Names for the demo staff, nurses and engineers interleaved.
     *
     * The order matters, because the licences run out long before the list
     * does. A scratch org affords four of these, so the front of the list
     * mixes nurses and engineers and both halves of the demo get staff.
     */
    private static final List<String> DEMO_USER_NAMES = new List<String>{
        'Amara Okafor', 'Bethan Rees', 'Nadia Rahimi', 'Chidi Nwosu',
        'Priyanka Shah', 'Dara Kelly', 'Elena Petrova', 'Tomas Novak',
        'Grace Adeyemi', 'Farida Hassan'
    };

    /**
     * Create Users for the demo staff, from whatever licences the org has.
     *
     * A ServiceResource must point at a User, and a scratch org arrives with
     * licences but with nobody holding them: one admin, and four spare
     * Salesforce or Salesforce Platform licences going unused.
     *
     * This has to be its own transaction, and that is not a preference. User is
     * a setup object, and Apex refuses DML on a setup object and a non-setup
     * object in the same transaction - "DML operation on setup object is not
     * permitted after you have updated a non-setup object (or vice versa)" -
     * in either order. So it is called on its own, from
     * scripts/apex/users.apex, before the seeder runs.
     *
     * Returns a sentence for whoever called it. Idempotent: it counts the
     * spare users that already exist and only makes up the difference.
     */
    public static String ensureDemoUsers() {
        return ensureDemoUsers(TimefoldRules.count('Seed.DemoUsers'));
    }

    /**
     * The count is a parameter so a test can ask for more than any org has.
     *
     * Otherwise the creation path is only ever reached on an org that happens
     * to be short of users, and it would go untested in exactly the org where
     * it is not needed and untested in the one where it is.
     */
    @TestVisible
    private static String ensureDemoUsers(Integer wanted) {
        if (!TimefoldRules.flag('Seed.CreateDemoUsers')) {
            return 'Seed.CreateDemoUsers is off, so no user was created.';
        }

        Set<Id> taken = new Set<Id>();
        for (ServiceResource resource : [
                SELECT RelatedRecordId FROM ServiceResource
                WHERE RelatedRecordId != NULL LIMIT 500]) {
            taken.add(resource.RelatedRecordId);
        }
        Integer spare = [
            SELECT COUNT() FROM User
            WHERE IsActive = TRUE AND Id NOT IN :taken
              AND Profile.UserLicense.Name IN ('Salesforce', 'Salesforce Platform')];
        if (spare >= wanted) {
            return 'The org already has ' + spare + ' user(s) free for demo '
                 + 'staff, so none was created.';
        }

        // Platform first: it is the cheaper licence and nothing the demo staff
        // do needs more. The admin's own Salesforce licence is left alone.
        List<Profile> profiles = [
            SELECT Id, Name, UserLicense.Name FROM Profile
            WHERE Name IN ('Standard Platform User', 'Standard User')];
        Map<String, Id> profileOf = new Map<String, Id>();
        Map<String, String> licenceOf = new Map<String, String>();
        for (Profile profile : profiles) {
            profileOf.put(profile.Name, profile.Id);
            licenceOf.put(profile.Name, profile.UserLicense.Name);
        }
        Map<String, Integer> free = new Map<String, Integer>();
        for (UserLicense licence : [
                SELECT Name, TotalLicenses, UsedLicenses FROM UserLicense
                WHERE Name IN ('Salesforce', 'Salesforce Platform')]) {
            free.put(licence.Name,
                     licence.TotalLicenses - licence.UsedLicenses);
        }

        String suffix = '.' + UserInfo.getOrganizationId().toLowerCase()
                      + '@timefold-demo.invalid';
        Set<String> existing = new Set<String>();
        for (User row : [SELECT Username FROM User LIMIT 2000]) {
            existing.add(row.Username);
        }

        List<User> newUsers = new List<User>();
        Integer index = 0;
        while (newUsers.size() < wanted - spare
                && index < DEMO_USER_NAMES.size()) {
            String name = DEMO_USER_NAMES[index];
            index++;
            String profileName = pickProfile(free, licenceOf);
            if (profileName == null) {
                break;                          // no licence left of either kind
            }
            free.put(licenceOf.get(profileName),
                     free.get(licenceOf.get(profileName)) - 1);

            List<String> parts = name.split(' ');
            String username = parts[0].toLowerCase() + '.'
                + parts[parts.size() - 1].toLowerCase() + suffix;
            if (existing.contains(username)) {
                continue;
            }
            newUsers.add(new User(
                Username = username,
                // A reserved domain, so nothing can ever be delivered. The
                // welcome email is switched off below as well; both, because
                // either one alone is a promise and not a guarantee.
                Email = username,
                FirstName = parts[0],
                LastName = parts[parts.size() - 1],
                Alias = alias(parts),
                ProfileId = profileOf.get(profileName),
                TimeZoneSidKey = 'Europe/London',
                LocaleSidKey = 'en_GB',
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US'));
        }

        Integer made = 0;
        List<String> refused = new List<String>();
        if (!newUsers.isEmpty()) {
            // Partial success, and no welcome email. A licence that turns out
            // not to be usable should cost one user, not all of them. The
            // address is a reserved .invalid domain as well: either alone is a
            // promise, and both together is a guarantee.
            Database.DMLOptions options = new Database.DMLOptions();
            options.EmailHeader.triggerUserEmail = false;
            options.optAllOrNone = false;
            for (Database.SaveResult saved
                    : Database.insert(newUsers, options)) {
                if (saved.isSuccess()) {
                    made++;
                } else {
                    for (Database.Error error : saved.getErrors()) {
                        refused.add(error.getMessage());
                    }
                }
            }
        }

        String granted = grantFieldService(taken);

        if (made == 0 && newUsers.isEmpty()) {
            return 'No licence left for a demo user: the org has ' + spare
                 + ' spare user(s) and ' + wanted + ' would be useful. ' + granted;
        }
        return 'Created ' + made + ' demo user(s)'
             + (refused.isEmpty() ? '. ' : '; ' + refused.size()
                + ' refused: ' + refused[0] + ' ') + granted;
    }

    /**
     * Let the demo users back a ServiceResource.
     *
     * Two things, and one without the other does nothing:
     *
     *   FieldServiceStandardPsl        the permission set LICENCE
     *   Timefold_Demo_Staff            a permission set granting
     *                                  FieldServiceAccess
     *
     * Without them Salesforce refuses the insert with "Looks like the selected
     * user doesn't have permission to be a service resource. Your Salesforce
     * admin can help with that." - which names no field, no permission and no
     * licence. A Standard Platform User cannot be a service resource until it
     * holds both; the admin's own Salesforce-licence profile already can, which
     * is why a demo seeded on a Developer Edition org appears to work and the
     * same seeder on a scratch org quietly produces two nurses out of five.
     *
     * Every DML here is on a setup object, like the User insert above it, so
     * this belongs in this transaction and nowhere else.
     */
    private static String grantFieldService(Set<Id> taken) {
        List<User> demo = [
            SELECT Id FROM User
            WHERE IsActive = TRUE
              AND Username LIKE '%@timefold-demo.invalid'
              AND Id NOT IN :taken
            LIMIT 200];
        if (demo.isEmpty()) {
            return '';
        }
        Set<Id> ids = new Map<Id, User>(demo).keySet();

        List<PermissionSetLicense> licences = [
            SELECT Id FROM PermissionSetLicense
            WHERE DeveloperName = 'FieldServiceStandardPsl' LIMIT 1];
        Set<Id> hasLicence = new Set<Id>();
        for (PermissionSetLicenseAssign row : [
                SELECT AssigneeId FROM PermissionSetLicenseAssign
                WHERE AssigneeId IN :ids
                  AND PermissionSetLicense.DeveloperName = 'FieldServiceStandardPsl']) {
            hasLicence.add(row.AssigneeId);
        }
        List<PermissionSetLicenseAssign> licenceRows =
            new List<PermissionSetLicenseAssign>();
        if (!licences.isEmpty()) {
            for (Id userId : ids) {
                if (!hasLicence.contains(userId)) {
                    licenceRows.add(new PermissionSetLicenseAssign(
                        AssigneeId = userId,
                        PermissionSetLicenseId = licences[0].Id));
                }
            }
        }
        Integer licensed = 0;
        for (Database.SaveResult saved
                : Database.insert(licenceRows, false)) {
            if (saved.isSuccess()) {
                licensed++;
            }
        }

        List<PermissionSet> staff = [
            SELECT Id FROM PermissionSet
            WHERE Name = 'Timefold_Demo_Staff' LIMIT 1];
        if (staff.isEmpty()) {
            return 'Timefold_Demo_Staff is not deployed, so the demo users '
                 + 'cannot be service resources yet.';
        }
        Set<Id> hasPermSet = new Set<Id>();
        for (PermissionSetAssignment row : [
                SELECT AssigneeId FROM PermissionSetAssignment
                WHERE AssigneeId IN :ids AND PermissionSetId = :staff[0].Id]) {
            hasPermSet.add(row.AssigneeId);
        }
        List<PermissionSetAssignment> permRows =
            new List<PermissionSetAssignment>();
        for (Id userId : ids) {
            if (!hasPermSet.contains(userId)) {
                permRows.add(new PermissionSetAssignment(
                    AssigneeId = userId, PermissionSetId = staff[0].Id));
            }
        }
        Integer permitted = 0;
        List<String> problems = new List<String>();
        for (Database.SaveResult saved : Database.insert(permRows, false)) {
            if (saved.isSuccess()) {
                permitted++;
            } else {
                for (Database.Error error : saved.getErrors()) {
                    problems.add(error.getMessage());
                }
            }
        }
        return 'Field Service: ' + licensed + ' licence(s) and ' + permitted
             + ' permission set(s) granted'
             + (problems.isEmpty() ? '.' : '; ' + problems[0]);
    }

    /** The cheapest profile with a licence still free, or null. */
    private static String pickProfile(Map<String, Integer> free,
                                      Map<String, String> licenceOf) {
        for (String profileName : new List<String>{
                'Standard Platform User', 'Standard User' }) {
            String licence = licenceOf.get(profileName);
            if (licence != null && free.get(licence) != null
                    && free.get(licence) > 0) {
                return profileName;
            }
        }
        return null;
    }

    /** Alias is capped at eight characters and has to be unique-ish. */
    private static String alias(List<String> parts) {
        String candidate = (parts[0].left(1)
            + parts[parts.size() - 1]).toLowerCase();
        return candidate.left(8);
    }

    // ---------------------------------------------------------- field service

    /** The territory the round covers, and the one region under it. */
    private static final String FS_ROOT = 'St. Elmore Field Service';
    private static final String FS_REGION = 'London North';

    /** Engineer certificates, as Skill records. DeveloperName is the key. */
    private static final Map<String, String> FIELD_SKILLS =
        new Map<String, String>{
            'Ventilator_Servicing'      => 'Ventilator Servicing',
            'Electrical_Safety_Testing' => 'Electrical Safety Testing',
            'Infusion_Pumps'            => 'Infusion Pumps',
            'Imaging_Calibration'       => 'Imaging Calibration'
        };

    private static final List<String> ENGINEERS = new List<String>{
        'Nadia Rahimi', 'Priyanka Shah', 'Tomas Novak', 'Grace Adeyemi'
    };

    // Declared after FS_REGION on purpose: Apex initialises static finals in
    // the order they are written, so this is null if it moves above it.
    private static final String ENGINEER_MARK =
        'Biomedical engineer, ' + FS_REGION + '.';

    /**
     * Home bases, one per engineer, north London.
     *
     * Coordinates rather than addresses: the Geocodes data integration rules
     * re-geocode any record carrying address text, so a seeded coordinate is
     * silently replaced by whatever Salesforce makes of the street.
     */
    private static final List<Decimal> ENGINEER_HOMES = new List<Decimal>{
        51.5762, -0.0979,      // Tottenham
        51.5870, -0.1553,      // Highgate
        51.5540, -0.1090,      // Holloway
        51.5620, -0.2000       // Cricklewood
    };

    /** What each engineer is certified for, cycled across however many exist. */
    private static final List<List<String>> FIELD_SKILL_SETS =
        new List<List<String>>{
            new List<String>{ 'Ventilator Servicing', 'Electrical Safety Testing',
                              'Infusion Pumps' },
            new List<String>{ 'Imaging Calibration', 'Electrical Safety Testing',
                              'Ventilator Servicing' },
            new List<String>{ 'Infusion Pumps', 'Electrical Safety Testing' },
            new List<String>{ 'Imaging Calibration', 'Infusion Pumps',
                              'Ventilator Servicing' }
        };

    /**
     * The round: one row per job.
     *
     * subject | latitude | longitude | minutes | certificate | window hours
     *
     * The window is how many hours from 08:00 the customer will accept. Nine
     * is the whole working day; the two short ones are what make the plan
     * interesting, because they cannot both be first.
     */
    private static final List<String> VISITS = new List<String>{
        'Ventilator Service - Northwood General|51.6130|-0.1180|90|Ventilator Servicing|9',
        'Infusion Pump Service - Bellwood Health Centre|51.5975|-0.0314|45|Infusion Pumps|4',
        'Electrical Safety Check - Kingsmead Care Home|51.5820|-0.0499|30|Electrical Safety Testing|9',
        'Imaging Unit Calibration - Elmfield Day Hospital|51.5690|-0.0820|150|Imaging Calibration|9',
        'Electrical Safety Check - Dunmore Care Home|51.5784|-0.0419|30|Electrical Safety Testing|9',
        'Ventilator Service - Ashgrove Clinic|51.5588|-0.0469|45|Ventilator Servicing|9',
        'Infusion Pump Service - Carlton Surgery|51.5450|-0.1420|30|Infusion Pumps|5',
        'Imaging Unit Calibration - Redhill Diagnostics|51.5910|-0.1980|150|Imaging Calibration|9',
        'Electrical Safety Check - Marlow House|51.5660|-0.1690|30|Electrical Safety Testing|9',
        'Ventilator Service - Priory Park Clinic|51.5860|-0.1290|45|Ventilator Servicing|9'
    };

    /**
     * Build the London round.
     *
     * Idempotent, and it re-anchors: every run moves the jobs onto the current
     * working week. That matters more than it sounds. A one-day dataset seeded
     * on Wednesday is in the past by Thursday, the dispatcher console opens on
     * whatever date it last showed, and an empty Gantt looks exactly like a
     * load that never happened. Re-running the seeder is the fix.
     */
    private static void ensureFieldService(Report report) {
        Map<String, Id> skillIds = fieldSkillIds(report);
        Id hours = ensureFieldHours();
        Map<String, Id> territoryIds = ensureRegions(hours, report);
        Id regionId = territoryIds.get(FS_REGION);

        List<ServiceResource> engineers =
            ensureEngineers(report, regionId, hours, skillIds);
        if (engineers.isEmpty()) {
            report.note += 'No engineer could be created: a ServiceResource '
                + 'needs a User and this org has no spare licence. The field '
                + 'service round was not seeded. ';
            return;
        }
        report.visits = ensureVisits(regionId, skillIds);
        ensureFieldAbsences(engineers);
    }

    /**
     * A lunch break for each engineer, on each day of the round.
     *
     * ResourceAbsence is the only place Field Service keeps "this person is
     * not available then", and TimefoldRoutesRequest turns each one into a
     * FIXED break on the shift it falls in. Without them the plan drives
     * straight through a break the Gantt is drawing, which looks like the
     * solver ignoring the data - and it was, until it read them.
     *
     * Deleted and rebuilt rather than reused, because these move with the
     * round: an absence left on last week's date is worse than none.
     */
    private static void ensureFieldAbsences(List<ServiceResource> engineers) {
        Set<Id> resourceIds = new Map<Id, ServiceResource>(engineers).keySet();
        String mark = 'Lunch, seeded by TimefoldSeed.';
        // Description is a textarea, and SOQL will not filter on one -
        // "field 'Description' can not be filtered in a query call" - so the
        // Type narrows it and the marker is matched here. Type alone would be
        // too broad: somebody else's meeting is not this seeder's to delete.
        List<ResourceAbsence> stale = new List<ResourceAbsence>();
        for (ResourceAbsence row : [
                SELECT Id, Description FROM ResourceAbsence
                WHERE ResourceId IN :resourceIds AND Type = 'Meeting'
                LIMIT 2000]) {
            if (row.Description == mark) {
                stale.add(row);
            }
        }
        if (!stale.isEmpty()) {
            Database.delete(stale, false);
        }

        Datetime dayStart = fieldServiceAnchor();
        Integer days = TimefoldRules.count('Routes.PlanningDays');
        List<ResourceAbsence> lunches = new List<ResourceAbsence>();
        for (ServiceResource engineer : engineers) {
            for (Integer day = 0; day < days; day++) {
                Datetime midday = dayStart.addDays(day).addHours(4);   // 12:00
                if (WEEKEND.contains(weekdayOf(midday))) {
                    continue;
                }
                lunches.add(new ResourceAbsence(
                    ResourceId = engineer.Id, Type = 'Meeting',
                    Start = midday, End = midday.addMinutes(30),
                    Description = mark));
            }
        }
        if (!lunches.isEmpty()) {
            Database.insert(lunches, false);
        }
    }

    private static final Set<String> WEEKEND =
        new Set<String>{ 'Saturday', 'Sunday' };

    private static final List<String> DAY_NAMES = new List<String>{
        'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday',
        'Saturday', 'Sunday'
    };

    /** Counted from a known Monday, not formatted: format answers in locale. */
    private static String weekdayOf(Datetime value) {
        Integer offset = Math.mod(Math.mod(
            Date.newInstance(2024, 1, 1).daysBetween(value.dateGmt()), 7) + 7, 7);
        return DAY_NAMES[offset];
    }

    private static Map<String, Id> fieldSkillIds(Report report) {
        Map<String, Id> byLabel = new Map<String, Id>();
        for (Skill row : [
                SELECT Id, DeveloperName, MasterLabel FROM Skill
                WHERE DeveloperName IN :FIELD_SKILLS.keySet()]) {
            byLabel.put(row.MasterLabel, row.Id);
        }
        if (byLabel.size() < FIELD_SKILLS.size()) {
            report.note += 'Missing engineer Skill records. Deploy them with: '
                + 'sf project deploy start --source-dir '
                + 'force-app/main/default/skills. ';
        }
        return byLabel;
    }

    /** Monday to Friday, 08:00 to 17:00. No weekend cover. */
    private static Id ensureFieldHours() {
        String name = 'Field service 08:00-17:00';
        List<OperatingHours> existing = [
            SELECT Id FROM OperatingHours WHERE Name = :name LIMIT 1];
        if (!existing.isEmpty()) {
            return existing[0].Id;
        }
        OperatingHours hours = new OperatingHours(
            Name = name, TimeZone = 'Europe/London',
            Description = 'Field service crew, Monday to Friday.');
        insert hours;
        List<TimeSlot> slots = new List<TimeSlot>();
        for (String day : new List<String>{
                'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday' }) {
            slots.add(new TimeSlot(
                OperatingHoursId = hours.Id, DayOfWeek = day, Type = 'Normal',
                StartTime = Time.newInstance(8, 0, 0, 0),
                EndTime = Time.newInstance(17, 0, 0, 0)));
        }
        insert slots;
        return hours.Id;
    }

    /**
     * The root territory and the region under it.
     *
     * Two levels because TimefoldRoutesExtract walks the subtree: one root
     * name in Routes.RootTerritory covers however many regions a real
     * deployment hangs off it.
     */
    private static Map<String, Id> ensureRegions(Id hours, Report report) {
        Map<String, Id> byName = new Map<String, Id>();
        for (ServiceTerritory row : [
                SELECT Id, Name FROM ServiceTerritory
                WHERE Name IN (:FS_ROOT, :FS_REGION)]) {
            byName.put(row.Name, row.Id);
        }
        if (!byName.containsKey(FS_ROOT)) {
            ServiceTerritory root = new ServiceTerritory(
                Name = FS_ROOT, OperatingHoursId = hours, IsActive = true,
                Latitude = 51.5072, Longitude = -0.1276,
                Description = 'Biomedical engineering team serving Greater London.');
            insert root;
            byName.put(FS_ROOT, root.Id);
        }
        if (!byName.containsKey(FS_REGION)) {
            ServiceTerritory region = new ServiceTerritory(
                Name = FS_REGION, OperatingHoursId = hours, IsActive = true,
                ParentTerritoryId = byName.get(FS_ROOT),
                Latitude = 51.5762, Longitude = -0.0979,
                Description = 'London North field service region.');
            insert region;
            byName.put(FS_REGION, region.Id);
        }
        report.regions = byName.size();
        return byName;
    }

    /**
     * The engineers, sized to the org like the nurses are.
     *
     * An engineer is a resource who is a member of the region, which is the
     * same rule TimefoldRoutesExtract uses. Anybody already in the region is
     * reused, so this never claims a resource another integration owns.
     */
    private static List<ServiceResource> ensureEngineers(
            Report report, Id regionId, Id hours, Map<String, Id> skillIds) {
        Set<Id> inRegion = new Set<Id>();
        for (ServiceTerritoryMember row : [
                SELECT ServiceResourceId FROM ServiceTerritoryMember
                WHERE ServiceTerritoryId = :regionId LIMIT 500]) {
            inRegion.add(row.ServiceResourceId);
        }

        Set<Id> takenUsers = new Set<Id>();
        for (ServiceResource row : [
                SELECT RelatedRecordId FROM ServiceResource
                WHERE RelatedRecordId != NULL LIMIT 500]) {
            takenUsers.add(row.RelatedRecordId);
        }

        Integer wanted = ENGINEERS.size() - inRegion.size();
        List<ServiceResource> created = new List<ServiceResource>();
        if (wanted > 0) {
            List<User> spare = preferring([
                SELECT Id, Name FROM User
                WHERE IsActive = TRUE AND Id NOT IN :takenUsers
                  AND Profile.UserLicense.Name IN ('Salesforce', 'Salesforce Platform')
                ORDER BY CreatedDate ASC LIMIT 20], ENGINEERS);
            for (User user : spare) {
                if (created.size() >= wanted) {
                    break;
                }
                created.add(new ServiceResource(
                    // The user's own name, not a name from a list. See
                    // preferring().
                    Name = user.Name,
                    ResourceType = 'T', IsActive = true,
                    RelatedRecordId = user.Id,
                    // Not capacity-based, unlike the nurses. A capacity-based
                    // resource gets no appointment bars at all in the
                    // dispatcher console.
                    Description = ENGINEER_MARK));
            }
            if (!created.isEmpty()) {
                Database.insert(created, false);
            }
        }
        for (ServiceResource row : created) {
            if (row.Id != null) {
                inRegion.add(row.Id);
            }
        }

        List<ServiceResource> engineers = [
            SELECT Id, Name FROM ServiceResource
            WHERE Id IN :inRegion AND IsActive = TRUE
            ORDER BY Name ASC LIMIT 200];
        report.engineers = engineers.size();
        if (engineers.isEmpty()) {
            return engineers;
        }

        ensureRegionMemberships(engineers, regionId, hours);
        ensureFieldSkills(engineers, skillIds);
        return engineers;
    }

    /**
     * Put each engineer in the region, with a home base.
     *
     * The home base lives on the membership, not on the resource: Latitude
     * there is where the territory expects them to start, while
     * ServiceResource.LastKnownLatitude is wherever the mobile app last saw
     * them. Without one the engineer cannot be routed at all.
     */
    private static void ensureRegionMemberships(
            List<ServiceResource> engineers, Id regionId, Id hours) {
        Map<Id, ServiceTerritoryMember> existing =
            new Map<Id, ServiceTerritoryMember>();
        for (ServiceTerritoryMember row : [
                SELECT Id, ServiceResourceId, Latitude, Longitude,
                       OperatingHoursId
                FROM ServiceTerritoryMember
                WHERE ServiceTerritoryId = :regionId LIMIT 500]) {
            existing.put(row.ServiceResourceId, row);
        }

        List<ServiceTerritoryMember> writes = new List<ServiceTerritoryMember>();
        Integer index = 0;
        for (ServiceResource engineer : engineers) {
            Decimal latitude = ENGINEER_HOMES[
                Math.mod(index * 2, ENGINEER_HOMES.size())];
            Decimal longitude = ENGINEER_HOMES[
                Math.mod(index * 2 + 1, ENGINEER_HOMES.size())];
            index++;

            ServiceTerritoryMember member = existing.get(engineer.Id);
            if (member == null) {
                writes.add(new ServiceTerritoryMember(
                    ServiceResourceId = engineer.Id,
                    ServiceTerritoryId = regionId,
                    TerritoryType = 'P', OperatingHoursId = hours,
                    EffectiveStartDate = Datetime.now().addYears(-1),
                    Latitude = latitude, Longitude = longitude));
            } else if (member.Latitude == null || member.OperatingHoursId == null) {
                writes.add(new ServiceTerritoryMember(
                    Id = member.Id,
                    OperatingHoursId = member.OperatingHoursId == null
                        ? hours : member.OperatingHoursId,
                    Latitude = member.Latitude == null ? latitude : member.Latitude,
                    Longitude = member.Longitude == null
                        ? longitude : member.Longitude));
            }
        }
        for (ServiceTerritoryMember write : writes) {
            if (write.Id == null) {
                Database.insert(new List<ServiceTerritoryMember>{ write }, false);
            } else {
                Database.update(new List<ServiceTerritoryMember>{ write }, false);
            }
        }
    }

    private static void ensureFieldSkills(List<ServiceResource> engineers,
                                          Map<String, Id> skillIds) {
        Set<String> held = new Set<String>();
        for (ServiceResourceSkill row : [
                SELECT ServiceResourceId, SkillId FROM ServiceResourceSkill
                LIMIT 5000]) {
            held.add(row.ServiceResourceId + ':' + row.SkillId);
        }
        List<ServiceResourceSkill> writes = new List<ServiceResourceSkill>();
        Integer index = 0;
        for (ServiceResource engineer : engineers) {
            List<String> certificates = FIELD_SKILL_SETS[
                Math.mod(index, FIELD_SKILL_SETS.size())];
            index++;
            for (String label : certificates) {
                Id skillId = skillIds.get(label);
                if (skillId == null
                        || held.contains(engineer.Id + ':' + skillId)) {
                    continue;
                }
                writes.add(new ServiceResourceSkill(
                    ServiceResourceId = engineer.Id, SkillId = skillId,
                    // Above the level the jobs demand, so a requirement is
                    // satisfiable rather than only just met.
                    SkillLevel = 7,
                    EffectiveStartDate = Datetime.now().addYears(-1)));
            }
        }
        if (!writes.isEmpty()) {
            Database.insert(writes, false);
        }
    }

    /**
     * The jobs, as WorkOrders with one ServiceAppointment each.
     *
     * The certificate a job needs is a SkillRequirement on the WorkOrder,
     * which is where Field Service keeps it, and where the extract looks.
     *
     * Coordinates and no street text, for the reason ENGINEER_HOMES gives.
     */
    private static Integer ensureVisits(Id regionId, Map<String, Id> skillIds) {
        Datetime dayStart = fieldServiceAnchor();

        Map<String, ServiceAppointment> existing =
            new Map<String, ServiceAppointment>();
        for (ServiceAppointment row : [
                SELECT Id, Subject, ParentRecordId FROM ServiceAppointment
                WHERE ServiceTerritoryId = :regionId LIMIT 2000]) {
            existing.put(row.Subject, row);
        }

        List<WorkOrder> orders = new List<WorkOrder>();
        List<String> pending = new List<String>();
        for (String row : VISITS) {
            if (!existing.containsKey(row.split('\\|')[0])) {
                pending.add(row);
            }
        }
        for (String row : pending) {
            List<String> parts = row.split('\\|');
            orders.add(new WorkOrder(
                Subject = parts[0], ServiceTerritoryId = regionId,
                Status = 'New', Latitude = Decimal.valueOf(parts[1]),
                Longitude = Decimal.valueOf(parts[2])));
        }
        if (!orders.isEmpty()) {
            Database.insert(orders, false);
        }

        List<ServiceAppointment> newVisits = new List<ServiceAppointment>();
        List<SkillRequirement> requirements = new List<SkillRequirement>();
        for (Integer i = 0; i < pending.size(); i++) {
            if (orders[i].Id == null) {
                continue;
            }
            List<String> parts = pending[i].split('\\|');
            Integer windowHours = Integer.valueOf(parts[5]);
            newVisits.add(new ServiceAppointment(
                ParentRecordId = orders[i].Id,
                ServiceTerritoryId = regionId,
                Subject = parts[0], Status = 'None',
                EarliestStartTime = dayStart,
                DueDate = dayStart.addHours(windowHours),
                Duration = Integer.valueOf(parts[3]),
                DurationType = 'Minutes',
                Latitude = Decimal.valueOf(parts[1]),
                Longitude = Decimal.valueOf(parts[2])));
            Id skillId = skillIds.get(parts[4]);
            if (skillId != null) {
                requirements.add(new SkillRequirement(
                    RelatedRecordId = orders[i].Id, SkillId = skillId,
                    SkillLevel = 5));
            }
        }
        if (!newVisits.isEmpty()) {
            Database.insert(newVisits, false);
        }
        if (!requirements.isEmpty()) {
            Database.insert(requirements, false);
        }

        // Re-anchor whatever was already there, so a second run brings a stale
        // round forward instead of leaving it in the past.
        List<ServiceAppointment> moves = new List<ServiceAppointment>();
        for (String row : VISITS) {
            List<String> parts = row.split('\\|');
            ServiceAppointment was = existing.get(parts[0]);
            if (was == null) {
                continue;
            }
            moves.add(new ServiceAppointment(
                Id = was.Id,
                EarliestStartTime = dayStart,
                DueDate = dayStart.addHours(Integer.valueOf(parts[5]))));
        }
        if (!moves.isEmpty()) {
            Database.update(moves, false);
        }

        return [SELECT COUNT() FROM ServiceAppointment
                WHERE ServiceTerritoryId = :regionId];
    }

    /**
     * 08:00 GMT on the next working day, today included while 08:00 is still
     * ahead.
     *
     * Both consoles open on today, so the round has to be there. A Saturday or
     * Sunday moves to the Monday: the crew has no weekend cover, so a weekend
     * anchor would produce a window with no shifts in it at all.
     *
     * Every date here is GMT, deliberately. Date.today() answers in the
     * running user's timezone, and the two are not the same day for a good
     * part of every day: a scratch org defaults to Pacific time, so seeding
     * from Europe before 17:00 local dated the whole round to *yesterday* in
     * GMT. Everything then worked - the plan was correct, the write-back was
     * correct - and the Gantt was empty, because the console opens on today
     * and the round was on the day before. That is indistinguishable from a
     * run that never happened.
     */
    @TestVisible
    private static Datetime fieldServiceAnchor() {
        Datetime rightNow = Datetime.now();
        Date day = rightNow.dateGmt();
        // A round that started before anybody finished setting the org up is a
        // round nobody can watch, so once 08:00 has gone, use tomorrow.
        if (Datetime.newInstanceGmt(day, Time.newInstance(8, 0, 0, 0)) <= rightNow) {
            day = day.addDays(1);
        }
        // Counting from a known Monday, because Datetime.format('EEEE') answers
        // in the running user's locale.
        Integer weekday = Math.mod(
            Math.mod(Date.newInstance(2024, 1, 1).daysBetween(day), 7) + 7, 7);
        if (weekday > 4) {
            day = day.addDays(7 - weekday);
        }
        return Datetime.newInstanceGmt(day, Time.newInstance(8, 0, 0, 0));
    }

    private static String categoryOf(String key) {
        if (key.startsWith('RoleSkill.')) { return 'RoleSkill'; }
        if (key.startsWith('Weight.')) { return 'Weight'; }
        if (key.startsWith('Routes.')) { return 'Routes'; }
        if (key.startsWith('Seed.')) { return 'Seed'; }
        return 'Roster';
    }
}
