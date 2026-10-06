/**
 * The rules that have no Salesforce home.
 *
 * Almost every rule in this integration comes out of Salesforce data:
 * certificates from ServiceResourceSkill, wards from ServiceTerritoryMember,
 * leave from ResourceAbsence, contract hours from ServiceResourceCapacity.
 * What is left over is labour policy and solver trade-offs, and Salesforce has
 * no object that says any of it.
 *
 * Every value has a built-in default, so a freshly deployed org optimises
 * correctly before anybody has configured anything. A Timefold_Setting__c
 * record with the matching Key overrides one, which is how an administrator
 * changes a weight without a deployment.
 *
 * Read once per transaction and cached: a queueable that builds a request
 * touches these dozens of times and a SOQL query per lookup would be absurd.
 */
public with sharing class TimefoldRules {

    /** Defaults, used when no Timefold_Setting__c record overrides them. */
    private static final Map<String, String> DEFAULTS = new Map<String, String>{
        // ---- roster labour rules ----------------------------------------
        'Roster.MinimumRestHours'              => '11',
        'Roster.MinimumRestSatisfiability'     => 'REQUIRED',
        'Roster.MaximumConsecutiveDays'        => '5',
        'Roster.MaximumConsecutiveSatisfiability' => 'REQUIRED',
        'Roster.MaximumShiftTypesPerWeek'      => '2',
        'Roster.MaximumShiftTypesSatisfiability'  => 'PREFERRED',
        'Roster.ContractHoursSatisfiability'   => 'PREFERRED',
        'Roster.ContractHoursMinimumFraction'  => '0.6',
        'Roster.MaximumWeekendsInWindow'       => '1',
        'Roster.WeekendWindowWeeks'            => '2',
        'Roster.MaximumWeekendsSatisfiability' => 'PREFERRED',
        'Roster.WardEligibilityEnabled'        => 'true',
        'Roster.WardSkillPrefix'               => 'Ward: ',
        'Roster.SolverSeconds'                 => '60',
        'Roster.PlanningDays'                  => '14',
        'Roster.RespectExisting'               => 'false',
        'Roster.AssignedStatus'                => 'Published',
        'Roster.UnassignedStatus'              => 'Tentative',
        'Roster.ClearUnassigned'               => 'true',

        // ---- the seeder -------------------------------------------------
        // A ServiceResource must point at a User, and a scratch org arrives
        // with licences but nobody holding them. Off, the seeder uses only the
        // users the org already has.
        'Seed.CreateDemoUsers'                 => 'true',
        'Seed.DemoUsers'                       => '8',
        // The rota is seeded first, so without a reservation the nurses claim
        // every spare licence and the round has nobody to route.
        'Seed.ReserveForEngineers'             => '2',

        // ---- routing rules ----------------------------------------------
        // The territory the round covers. Everything under it is in scope, so
        // one root name is enough however many regions hang off it.
        'Routes.RootTerritory'                 => 'St. Elmore Field Service',
        'Routes.RestrictToOwnRegion'           => 'true',
        // Only used when a ServiceTerritoryMember has no OperatingHours. The
        // day list matters: without it the solver books a Sunday quite happily.
        'Routes.DefaultWorkDays'
            => 'Monday;Tuesday;Wednesday;Thursday;Friday',
        'Routes.ShiftStartHour'                => '8',
        'Routes.ShiftEndHour'                  => '17',
        'Routes.OvertimeMinutes'               => '30',
        'Routes.ReturnToHome'                  => 'true',
        'Routes.SolverSeconds'                 => '60',
        'Routes.PlanningDays'                  => '3',
        'Routes.ScheduledStatus'               => 'Scheduled',
        'Routes.UnscheduledStatus'             => 'None',
        // Leave becomes a fixed break on the shift it falls in. Off, the
        // solver drives straight through a break the Gantt is drawing.
        'Routes.BreaksFromAbsences'            => 'true',
        // Do not move what a person has already committed to. On by default,
        // unlike the roster's equivalent: a job already sent to an engineer
        // is not a planning decision any more.
        'Routes.RespectExisting'               => 'true',
        'Routes.PinnedStatusCategories'
            => 'Dispatched;InProgress;Completed;CannotComplete',

        // ---- which certificates a role demands --------------------------
        // Semicolon separated. A role with no certificate needs no row.
        'RoleSkill.ICU Registered Nurse' => 'ICU Certification;Ventilator Management',
        'RoleSkill.Emergency Nurse'      => 'Triage;Advanced Cardiac Life Support',
        'RoleSkill.Charge Nurse'         => 'Charge Nurse',
        'RoleSkill.Registered Nurse'     => 'Medication Administration',

        // ---- solver weights ---------------------------------------------
        // Balance has to outweigh everything, or the solver is content to run
        // a ward with two people and leave the rest idle: an idle nurse costs
        // nothing unless being idle is itself a penalty.
        'Weight.Roster.minimizeActivatedEmployeesWeight' => '0',
        'Weight.Roster.balanceShiftCountWeight'          => '100',
        'Weight.Roster.balanceTimeWorkedWeight'          => '100',
        'Weight.Roster.minutesWorkedPerPeriodNotInPreferredRangeForEmployeeWeight' => '50',
        'Weight.Roster.consecutiveDaysWorkedNotInPreferredRangeForEmployeeWeight'  => '20',
        'Weight.Roster.shiftTypesWorkedPerPeriodNotInPreferredRangeForEmployeeWeight' => '15',
        'Weight.Roster.weekendsWorkedPerPeriodNotInPreferredRangeForEmployeeWeight'   => '25',
        'Weight.Roster.preferredSkillMissingWeight'      => '5',
        // Pick ONE travel objective. Timefold raises TRAVEL_WEIGHT_CONFLICT if
        // both travel weights are non-zero, and the run still succeeds, so the
        // warning is easy to ship.
        'Weight.Routes.balanceTimeUtilizationWeight'     => '100',
        'Weight.Routes.minimizeTravelTimeWeight'         => '30',
        'Weight.Routes.minimizeTravelDistanceWeight'     => '0',
        'Weight.Routes.minimizeUnnecessarySkillsWeight'  => '5'
    };

    private static Map<String, String> configured;

    /** Every setting, defaults with any Timefold_Setting__c rows applied over. */
    private static Map<String, String> all() {
        if (configured != null) {
            return configured;
        }
        configured = new Map<String, String>(DEFAULTS);
        for (Timefold_Setting__c row : [
                SELECT Name, Value__c FROM Timefold_Setting__c
                WHERE Value__c != NULL LIMIT 2000]) {
            configured.put(row.Name, row.Value__c);
        }
        return configured;
    }

    /** Forget the cache. Only tests need this. */
    @TestVisible
    private static void reset() {
        configured = null;
    }

    public static String text(String key) {
        return all().get(key);
    }

    public static Decimal number(String key) {
        String raw = all().get(key);
        try {
            return String.isBlank(raw) ? null : Decimal.valueOf(raw.trim());
        } catch (Exception e) {
            // A setting somebody typed by hand should not take the run down
            // silently, but it must not be guessed at either.
            throw new TimefoldClient.TimefoldException(
                'Timefold setting ' + key + ' is "' + raw + '", which is not a number.');
        }
    }

    public static Integer count(String key) {
        Decimal value = number(key);
        return value == null ? null : value.intValue();
    }

    public static Boolean flag(String key) {
        String raw = all().get(key);
        return raw != null && (raw.trim().toLowerCase() == 'true'
                            || raw.trim() == '1'
                            || raw.trim().toLowerCase() == 'yes');
    }

    /** Every key that has a built-in default. TimefoldSeed writes these out. */
    public static Set<String> defaultKeys() {
        return DEFAULTS.keySet();
    }

    /** The built-in value for a key, ignoring any record that overrides it. */
    public static String defaultFor(String key) {
        return DEFAULTS.get(key);
    }

    /** Role name -> the certificates it demands. */
    public static Map<String, List<String>> roleSkills() {
        Map<String, List<String>> out = new Map<String, List<String>>();
        for (String key : all().keySet()) {
            if (!key.startsWith('RoleSkill.')) {
                continue;
            }
            String role = key.substring('RoleSkill.'.length());
            List<String> skills = new List<String>();
            for (String piece : (all().get(key) == null ? '' : all().get(key)).split(';')) {
                if (String.isNotBlank(piece)) {
                    skills.add(piece.trim());
                }
            }
            out.put(role, skills);
        }
        return out;
    }

    /**
     * Constraint weights for one model, as Timefold's config.model.overrides.
     *
     * Zero is kept rather than dropped: setting a weight to zero is how you
     * turn a constraint off, and omitting it would restore the model default.
     */
    public static Map<String, Object> weights(String model) {
        String prefix = 'Weight.' + model + '.';
        Map<String, Object> out = new Map<String, Object>();
        for (String key : all().keySet()) {
            if (key.startsWith(prefix)) {
                out.put(key.substring(prefix.length()), number(key));
            }
        }
        return out;
    }
}
