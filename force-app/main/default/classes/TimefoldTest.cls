/**
 * Tests for the whole roster pipeline, without touching Timefold.
 *
 * Salesforce will not deploy Apex to a Developer Edition org without tests, so
 * some of this exists to satisfy that. The rest pins the details that are
 * expensive to get wrong and invisible when they are:
 *
 *   - MATCH_ALL rather than ALL, which a live request rejects
 *   - rule ids scoped by contract, because Timefold binds them dataset-wide
 *     and two contracts sharing one is DATASET_INVALID
 *   - a preferred minimum on contract hours, without which a maximum alone
 *     leaves half the ward idle and nothing looks wrong
 *   - a rolling window for weekends, because a WEEK rule for "one weekend in
 *     two" is valid, accepted and completely inert
 *   - the night-shift span merge, because a Salesforce TimeSlot cannot cross
 *     midnight and two unmerged halves make every night nurse unavailable for
 *     their own shift
 */
@IsTest
private class TimefoldTest {

    /** Answers whatever the test asked for, and checks how it was asked. */
    private class Responder implements HttpCalloutMock {
        private final Integer status;
        private final String body;
        public String lastBody;
        public String lastEndpoint;
        Responder(Integer status, String body) {
            this.status = status;
            this.body = body;
        }
        public HttpResponse respond(HttpRequest request) {
            lastEndpoint = request.getEndpoint();
            lastBody = request.getBody();
            System.assert(request.getEndpoint().startsWith('callout:Timefold'),
                'every call must go through the Named Credential, never a raw URL');
            HttpResponse reply = new HttpResponse();
            reply.setStatusCode(status);
            reply.setBody(body);
            return reply;
        }
    }

    // ------------------------------------------------------------- the client

    @IsTest
    static void submitReadsABareJobId() {
        Test.setMock(HttpCalloutMock.class, new Responder(200, '"job-123"'));
        Test.startTest();
        String id = TimefoldClient.submit(TimefoldClient.employeeScheduling(), '{}');
        Test.stopTest();
        System.assertEquals('job-123', id,
            'Timefold answers a submit with the id as a bare JSON string');
    }

    @IsTest
    static void submitAlsoReadsAnObjectForm() {
        Test.setMock(HttpCalloutMock.class, new Responder(200, '{"id":"job-9"}'));
        Test.startTest();
        System.assertEquals('job-9',
            TimefoldClient.submit(TimefoldClient.employeeScheduling(), '{}'));
        Test.stopTest();
    }

    @IsTest
    static void anUnauthorisedCallSaysWhereToPutTheKey() {
        Test.setMock(HttpCalloutMock.class, new Responder(401, 'nope'));
        Test.startTest();
        try {
            TimefoldClient.aboutMe();
            System.assert(false, 'a 401 must not pass silently');
        } catch (TimefoldClient.TimefoldException e) {
            System.assert(e.getMessage().contains('External Credentials'),
                'the message has to say where the key goes: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void anErrorBodyIsReportedNotSwallowed() {
        Test.setMock(HttpCalloutMock.class,
                     new Responder(400, '{"detail":"Referencing an undeclared tag"}'));
        Test.startTest();
        try {
            TimefoldClient.status(TimefoldClient.employeeScheduling(), 'x');
            System.assert(false, 'a 400 must throw');
        } catch (TimefoldClient.TimefoldException e) {
            System.assert(e.getMessage().contains('undeclared tag'),
                'the body carries the only useful detail: ' + e.getMessage());
        }
        Test.stopTest();
    }

    // -------------------------------------------------------------- the rules

    @IsTest
    static void defaultsApplyBeforeAnythingIsConfigured() {
        TimefoldRules.reset();
        System.assertEquals(11, TimefoldRules.number('Roster.MinimumRestHours'));
        System.assertEquals(5, TimefoldRules.count('Roster.MaximumConsecutiveDays'));
        System.assertEquals(true, TimefoldRules.flag('Roster.WardEligibilityEnabled'));
        System.assertEquals(false, TimefoldRules.flag('Roster.RespectExisting'),
            'off by default, or a second run has everything pinned');
    }

    @IsTest
    static void aRecordOverridesADefault() {
        insert new Timefold_Setting__c(Name = 'Roster.MinimumRestHours',
                                       Value__c = '12', Category__c = 'Roster');
        TimefoldRules.reset();
        System.assertEquals(12, TimefoldRules.number('Roster.MinimumRestHours'));
    }

    @IsTest
    static void aWeightOfZeroIsKeptNotDropped() {
        TimefoldRules.reset();
        Map<String, Object> weights = TimefoldRules.weights('Routes');
        System.assert(weights.containsKey('minimizeTravelDistanceWeight'),
            'zero is how a constraint is turned off; dropping it restores the '
            + 'model default and both travel weights end up non-zero');
        System.assertEquals(0, weights.get('minimizeTravelDistanceWeight'));
    }

    @IsTest
    static void aSettingThatIsNotANumberSaysSo() {
        insert new Timefold_Setting__c(Name = 'Roster.SolverSeconds',
                                       Value__c = 'quickly', Category__c = 'Roster');
        TimefoldRules.reset();
        try {
            TimefoldRules.count('Roster.SolverSeconds');
            System.assert(false, 'a typed setting must not be guessed at');
        } catch (TimefoldClient.TimefoldException e) {
            System.assert(e.getMessage().contains('not a number'), e.getMessage());
        }
    }

    @IsTest
    static void roleSkillsSplitOnSemicolons() {
        TimefoldRules.reset();
        Map<String, List<String>> roles = TimefoldRules.roleSkills();
        System.assertEquals(2, roles.get('ICU Registered Nurse').size());
        System.assert(roles.get('ICU Registered Nurse').contains('Ventilator Management'));
    }

    // ------------------------------------------------------------- the request

    @IsTest
    static void theRequestCarriesTheDetailsALiveCallWouldRejectOrIgnore() {
        TimefoldRules.reset();
        TimefoldRosterExtract.Problem problem = sampleProblem();

        Test.startTest();
        String body = TimefoldRosterRequest.build(problem);
        Test.stopTest();

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(body);
        Map<String, Object> input = (Map<String, Object>) parsed.get('modelInput');

        // MATCH_ALL. The docs example does not set the field at all.
        List<Object> shifts = (List<Object>) input.get('shifts');
        Map<String, Object> shift = (Map<String, Object>) shifts[0];
        System.assertEquals('MATCH_ALL', shift.get('requiredSkillsMatchKind'));

        // Ward eligibility rides on the skill mechanism.
        List<Object> required = (List<Object>) shift.get('requiredSkills');
        System.assert(String.valueOf(required).contains('Ward: ICU'),
            'ward membership is expressed as a synthetic skill: ' + required);

        // The planning window is start/end here. Field Service Routing spells
        // the same idea startDate/endDate.
        Map<String, Object> window = (Map<String, Object>) input.get('planningWindow');
        System.assert(window.containsKey('start') && window.containsKey('end'));

        // Every tag a shift references has to be declared up front.
        Set<String> declared = new Set<String>();
        for (Object item : (List<Object>) input.get('tags')) {
            declared.add(String.valueOf(((Map<String, Object>) item).get('id')));
        }
        for (Object item : shifts) {
            for (Object tag : (List<Object>) ((Map<String, Object>) item).get('tags')) {
                System.assert(declared.contains(String.valueOf(tag)),
                    'undeclared tag ' + tag + ' would be DATASET_INVALID');
            }
        }
    }

    @IsTest
    static void ruleIdsAreUniqueAcrossTheWholeDataset() {
        TimefoldRules.reset();
        // Two nurses on different contracts, so two contracts are built.
        TimefoldRosterExtract.Problem problem = sampleProblem();
        problem.nurses[1].capacityHoursPerMonth = 104;      // a second contract

        String body = TimefoldRosterRequest.build(problem);
        Map<String, Object> input = (Map<String, Object>)
            ((Map<String, Object>) JSON.deserializeUntyped(body)).get('modelInput');
        List<Object> contracts = (List<Object>) input.get('contracts');
        System.assert(contracts.size() >= 2, 'expected two contracts');

        Set<String> ids = new Set<String>();
        Integer seen = 0;
        for (Object item : contracts) {
            for (String ruleGroup : new List<String>{
                    'minutesBetweenShiftsRules', 'consecutiveDaysWorkedRules',
                    'periodRules', 'rollingWindowRules' }) {
                Object rules = ((Map<String, Object>) item).get(ruleGroup);
                if (!(rules instanceof List<Object>)) {
                    continue;
                }
                for (Object rule : (List<Object>) rules) {
                    ids.add(String.valueOf(((Map<String, Object>) rule).get('id')));
                    seen++;
                }
            }
        }
        System.assertEquals(seen, ids.size(),
            'Timefold binds rule ids across the whole dataset, so two contracts '
            + 'sharing one is rejected with DATASET_INVALID');
    }

    @IsTest
    static void contractHoursCarryAPreferredFloorNotJustACeiling() {
        TimefoldRules.reset();
        String body = TimefoldRosterRequest.build(sampleProblem());
        Map<String, Object> input = (Map<String, Object>)
            ((Map<String, Object>) JSON.deserializeUntyped(body)).get('modelInput');
        Boolean foundFloor = false;
        for (Object item : (List<Object>) input.get('contracts')) {
            Object rules = ((Map<String, Object>) item).get('periodRules');
            if (!(rules instanceof List<Object>)) {
                continue;
            }
            for (Object rule : (List<Object>) rules) {
                Object worked = ((Map<String, Object>) rule).get('minutesWorkedLimit');
                if (worked instanceof Map<String, Object>
                        && ((Map<String, Object>) worked).containsKey('minutesWorkedMin')) {
                    foundFloor = true;
                }
            }
        }
        System.assert(foundFloor,
            'a maximum alone does not spread work: leaving somebody idle costs '
            + 'nothing, so the solver staffs a ward with two people');
    }

    @IsTest
    static void weekendsUseARollingWindowNotAWeekPeriod() {
        TimefoldRules.reset();
        String body = TimefoldRosterRequest.build(sampleProblem());
        System.assert(body.contains('rollingWindowRules'),
            '"one weekend in two" as a WEEK rule is valid, accepted and inert, '
            + 'because a week only ever contains one weekend');
        System.assert(body.contains('WEEKLY'));
    }

    @IsTest
    static void aNightRotaStoredAsTwoSlotsBecomesOneSpan() {
        TimefoldRules.reset();
        TimefoldRosterExtract.Problem problem = sampleProblem();

        // A Salesforce TimeSlot cannot cross midnight, so 23:00-07:00 is stored
        // as two rows a day apart.
        Id hoursId = problem.nurses[0].operatingHoursId;
        List<TimefoldRosterExtract.DailyWindow> night =
            new List<TimefoldRosterExtract.DailyWindow>();
        for (String day : new List<String>{
                'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday',
                'Saturday', 'Sunday' }) {
            TimefoldRosterExtract.DailyWindow late = new TimefoldRosterExtract.DailyWindow();
            late.dayOfWeek = day;
            late.startSeconds = 23 * 3600;
            late.endSeconds = 23 * 3600 + 59 * 60 + 59;
            night.add(late);
            TimefoldRosterExtract.DailyWindow early = new TimefoldRosterExtract.DailyWindow();
            early.dayOfWeek = day;
            early.startSeconds = 0;
            early.endSeconds = 7 * 3600;
            night.add(early);
        }
        problem.operatingHours.put(hoursId, night);

        List<Object> spans = TimefoldRosterRequest.availabilitySpans(
            night, problem.windowStart, problem.windowEnd);
        System.assert(!spans.isEmpty(), 'night hours are narrower than a whole day');

        // 23:00 to 07:00 is eight hours. Unmerged it would be 59 minutes plus
        // seven hours, and no night shift would fit either half.
        Map<String, Object> first = (Map<String, Object>) spans[0];
        System.assert(String.valueOf(first.get('start')).endsWith('T00:00:00Z')
                   || String.valueOf(first.get('start')).contains('T23:00:00Z'),
            'unexpected first span: ' + first);
        Boolean anyLongSpan = false;
        for (Object item : spans) {
            Map<String, Object> span = (Map<String, Object>) item;
            Datetime spanFrom = (Datetime) JSON.deserialize(
                '"' + String.valueOf(span.get('start')) + '"', Datetime.class);
            Datetime until = (Datetime) JSON.deserialize(
                '"' + String.valueOf(span.get('end')) + '"', Datetime.class);
            if (until.getTime() - spanFrom.getTime() >= 8 * 3600 * 1000) {
                anyLongSpan = true;
            }
        }
        System.assert(anyLongSpan,
            'the late and early slots must be joined into one eight-hour span');
    }

    @IsTest
    static void roundTheClockHoursProduceNoSpansAtAll() {
        TimefoldRules.reset();
        List<TimefoldRosterExtract.DailyWindow> always =
            new List<TimefoldRosterExtract.DailyWindow>();
        for (String day : new List<String>{
                'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday',
                'Saturday', 'Sunday' }) {
            TimefoldRosterExtract.DailyWindow w = new TimefoldRosterExtract.DailyWindow();
            w.dayOfWeek = day;
            w.startSeconds = 0;
            w.endSeconds = 86399;
            always.add(w);
        }
        Datetime openAt = Datetime.newInstanceGmt(2026, 9, 7, 0, 0, 0);
        System.assertEquals(0,
            TimefoldRosterRequest.availabilitySpans(always, openAt, openAt.addDays(14)).size(),
            'restricting availability to "always" adds a fortnight of redundant '
            + 'spans to every nurse in the payload');
    }

    // ----------------------------------------------------------- the writeback

    @IsTest
    static void theSolutionIsReadBackOntoTheShiftsItCameFrom() {
        TimefoldRules.reset();
        TimefoldRosterExtract.Problem problem = seededProblem();
        String shiftId = String.valueOf(problem.shifts[0].recordId);

        Map<String, Object> solution = new Map<String, Object>{
            'modelOutput' => new Map<String, Object>{
                'shifts' => new List<Object>{
                    new Map<String, Object>{
                        'id' => shiftId, 'employee' => problem.nurses[0].name }
                }
            }
        };
        Map<String, String> assignments =
            TimefoldRosterWriteback.assignmentsFrom(solution);
        System.assertEquals(1, assignments.size());

        Test.startTest();
        TimefoldRosterWriteback.Result result =
            TimefoldRosterWriteback.apply(problem, assignments);
        Test.stopTest();

        System.assertEquals(1, result.assigned, String.valueOf(result.errors));
        Shift written = [SELECT ServiceResourceId, Status FROM Shift
                         WHERE Id = :shiftId LIMIT 1];
        System.assertEquals(problem.nurses[0].recordId, written.ServiceResourceId,
            'the answer goes onto the standard field Salesforce itself writes');
        System.assertEquals('Published', written.Status);
    }

    @IsTest
    static void anEmployeeThisOrgDoesNotHaveIsReportedNotDropped() {
        TimefoldRules.reset();
        TimefoldRosterExtract.Problem problem = seededProblem();
        Map<String, String> assignments = new Map<String, String>{
            String.valueOf(problem.shifts[0].recordId) => 'Somebody Else'
        };
        Test.startTest();
        TimefoldRosterWriteback.Result result =
            TimefoldRosterWriteback.apply(problem, assignments);
        Test.stopTest();
        System.assertEquals(0, result.assigned);
        System.assert(result.unknownEmployees.contains('Somebody Else'),
            'dropping it silently would look like an unfillable shift');
    }

    @IsTest
    static void anObjectShapedEmployeeIsToleratedToo() {
        Map<String, String> assignments = TimefoldRosterWriteback.assignmentsFrom(
            new Map<String, Object>{
                'modelOutput' => new Map<String, Object>{
                    'shifts' => new List<Object>{
                        new Map<String, Object>{ 'id' => 'a',
                            'employee' => new Map<String, Object>{ 'id' => 'Amara' } }
                    }
                }
            });
        System.assertEquals('Amara', assignments.get('a'),
            'a future shape change must not silently clear a roster');
    }

    // ----------------------------------------------------------------- the job

    @IsTest
    static void aRunRecordsWhatHappened() {
        TimefoldRules.reset();
        seedOrg();
        Test.setMock(HttpCalloutMock.class, new Responder(200, '"job-abc"'));
        Test.startTest();
        Id runId = TimefoldJob.start('Roster');
        Test.stopTest();                    // runs the enqueued SUBMIT phase

        Timefold_Run__c run = [
            SELECT Status__c, Timefold_Job_Id__c, Records_Planned__c, Error__c
            FROM Timefold_Run__c WHERE Id = :runId LIMIT 1];
        // System.assertEquals refuses a null message argument, and Error__c is
        // null on a run that worked.
        String because = 'Error__c: ' + run.Error__c;
        System.assertEquals('job-abc', run.Timefold_Job_Id__c, because);
        System.assertEquals('Submitted', run.Status__c, because);
        System.assert(run.Records_Planned__c > 0, 'shifts should have been sent');
    }

    @IsTest
    static void asecondRunIsRefusedWhileOneIsInFlight() {
        insert new Timefold_Run__c(Model__c = 'Roster', Status__c = 'Solving');
        Test.startTest();
        Id again = TimefoldJob.start('Roster');
        Test.stopTest();
        System.assertEquals(1, [SELECT COUNT() FROM Timefold_Run__c],
            'thirty callouts from one action must not become thirty datasets');
        System.assertNotEquals(null, again);
    }

    @IsTest
    static void theInvocableNamesTheScopeItActuallyReplans() {
        TimefoldRules.reset();
        seedOrg();
        Test.setMock(HttpCalloutMock.class, new Responder(200, '"job-x"'));
        TimefoldPlanner.Request request = new TimefoldPlanner.Request();
        request.model = 'Roster';
        Test.startTest();
        List<TimefoldPlanner.Result> results = TimefoldPlanner.run(
            new List<TimefoldPlanner.Request>{ request });
        Test.stopTest();
        System.assertEquals(1, results.size());
        System.assertEquals(true, results[0].started, results[0].message);
        System.assert(results[0].message.contains('whole nurse rota'),
            'a message that says only "optimising" invites the reader to think '
            + 'it did something smaller: ' + results[0].message);
    }

    // ------------------------------------------------------------------ set-up

    /**
     * A problem built in memory, with no records.
     *
     * Field Service objects need an active org feature and a licensed user to
     * create, so the translate tests use a hand-built problem rather than data.
     */
    private static TimefoldRosterExtract.Problem sampleProblem() {
        TimefoldRosterExtract.Problem problem = new TimefoldRosterExtract.Problem();
        problem.windowStart = Datetime.newInstanceGmt(2026, 9, 7, 0, 0, 0);
        problem.windowEnd = problem.windowStart.addDays(14);

        Id fakeHours = fakeId(OperatingHours.SObjectType, 1);
        for (Integer i = 0; i < 2; i++) {
            TimefoldRosterExtract.Nurse nurse = new TimefoldRosterExtract.Nurse();
            nurse.recordId = fakeId(ServiceResource.SObjectType, i + 1);
            nurse.name = 'Nurse ' + i;
            nurse.skills.put('ICU Certification', 9);
            nurse.skills.put('Ventilator Management', 7);
            nurse.wards.add('ICU');
            nurse.operatingHoursId = fakeHours;
            nurse.capacityHoursPerMonth = 173;
            problem.nurses.add(nurse);
        }
        problem.operatingHours.put(fakeHours,
                                   new List<TimefoldRosterExtract.DailyWindow>());

        for (Integer i = 0; i < 3; i++) {
            TimefoldRosterExtract.ShiftDemand demand =
                new TimefoldRosterExtract.ShiftDemand();
            demand.recordId = fakeId(Shift.SObjectType, i + 1);
            demand.label = 'ICU Day';
            demand.startAt = problem.windowStart.addDays(i).addHours(7);
            demand.endAt = demand.startAt.addHours(8);
            demand.ward = 'ICU';
            demand.role = 'ICU Registered Nurse';
            problem.shifts.add(demand);
        }

        TimefoldRosterExtract.Absence absence = new TimefoldRosterExtract.Absence();
        absence.resourceId = problem.nurses[0].recordId;
        absence.kind = 'Vacation';
        absence.startAt = problem.windowStart.addDays(2);
        absence.endAt = problem.windowStart.addDays(4);
        problem.absences.add(absence);

        return problem;
    }

    /** Real records, for the writeback and job tests. */
    private static void seedOrg() {
        OperatingHours hours = new OperatingHours(Name = 'Test 24/7',
                                                  TimeZone = 'Europe/London');
        insert hours;
        ServiceTerritory ward = new ServiceTerritory(
            Name = 'ICU', OperatingHoursId = hours.Id, IsActive = true);
        insert ward;
        ServiceResource nurse = new ServiceResource(
            Name = 'Test Nurse', ResourceType = 'T', IsActive = true,
            IsCapacityBased = true, RelatedRecordId = UserInfo.getUserId());
        insert nurse;
        // Salesforce refuses to put a resource on a Shift unless they are a
        // member of that territory for those dates: "This service resource
        // isn't a member of the service territory". The roster cannot produce
        // such an assignment - ward membership is a required skill - but the
        // write-back would fail on it, so the test seeds the membership too.
        insert new ServiceTerritoryMember(
            ServiceResourceId = nurse.Id, ServiceTerritoryId = ward.Id,
            TerritoryType = 'P', OperatingHoursId = hours.Id,
            EffectiveStartDate = Datetime.now().addDays(-7));
        insert new Shift(
            ServiceTerritoryId = ward.Id,
            StartTime = Datetime.now().addDays(1),
            EndTime = Datetime.now().addDays(1).addHours(8),
            Status = 'Tentative', Label = 'ICU Day');
    }

    private static TimefoldRosterExtract.Problem seededProblem() {
        seedOrg();
        return TimefoldRosterExtract.run(14);
    }

    /** A syntactically valid id for a record that does not exist. */
    private static Id fakeId(Schema.SObjectType type, Integer index) {
        String suffix = String.valueOf(index);
        return Id.valueOf(type.getDescribe().getKeyPrefix()
            + '0'.repeat(12 - suffix.length()) + suffix);
    }
}
