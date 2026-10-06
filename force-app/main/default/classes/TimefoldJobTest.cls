/**
 * The asynchronous half, and the seeder.
 *
 * Salesforce requires 75% coverage per class to deploy with tests, and the poll
 * and finish phases are most of TimefoldJob.
 */
@IsTest
private class TimefoldJobTest {

    /**
     * Answers according to which endpoint was asked.
     *
     * The three GETs a run makes are different requests with different shapes:
     * /metadata carries the solver status, the bare id carries the whole
     * solution, and /validation-result carries the warnings. A single canned
     * reply would let a test pass with them swapped.
     */
    private class Chatty implements HttpCalloutMock {
        private final String solverStatus;
        private final String employee;
        private final String shiftId;
        public Integer metadataCalls = 0;
        public Integer solutionCalls = 0;
        public Integer validationCalls = 0;

        Chatty(String solverStatus, String shiftId, String employee) {
            this.solverStatus = solverStatus;
            this.shiftId = shiftId;
            this.employee = employee;
        }

        public HttpResponse respond(HttpRequest request) {
            String endpoint = request.getEndpoint();
            HttpResponse reply = new HttpResponse();
            reply.setStatusCode(200);
            if (endpoint.endsWith('/metadata')) {
                metadataCalls++;
                reply.setBody(JSON.serialize(new Map<String, Object>{
                    'solverStatus' => solverStatus,
                    'score' => '0hard/0medium/-1200soft',
                    'failureMessage' => solverStatus == 'DATASET_INVALID'
                        ? 'Referencing an undeclared tag' : null }));
            } else if (endpoint.endsWith('/validation-result')) {
                validationCalls++;
                reply.setBody(JSON.serialize(new Map<String, Object>{
                    'status' => 'WARNING',
                    'issues' => new List<Object>{
                        new Map<String, Object>{ 'code' => 'TRAVEL_WEIGHT_CONFLICT' } } }));
            } else if (request.getMethod() == 'POST') {
                reply.setBody('"job-async"');
            } else {
                solutionCalls++;
                reply.setBody(JSON.serialize(new Map<String, Object>{
                    'score' => '0hard/0medium/-1200soft',
                    'modelOutput' => new Map<String, Object>{
                        'shifts' => new List<Object>{
                            new Map<String, Object>{
                                'id' => shiftId, 'employee' => employee } } } }));
            }
            return reply;
        }
    }

    // -------------------------------------------------------------- the polls

    @IsTest
    static void aFinishedRunIsWrittenBackAndClosed() {
        Fixture fixture = seed();
        Timefold_Run__c run = startedRun('job-async');
        Chatty mock = new Chatty('SOLVING_COMPLETED', fixture.shiftId,
                                 fixture.nurseName);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        new TimefoldJob(run.Id, TimefoldJob.Phase.POLL).execute(null);
        Test.stopTest();

        Timefold_Run__c after = [
            SELECT Status__c, Score__c, Records_Written__c, Validation_Status__c,
                   Validation_Detail__c, Unassigned__c, Error__c, Finished__c
            FROM Timefold_Run__c WHERE Id = :run.Id LIMIT 1];
        System.assertEquals('Done', after.Status__c, 'Error__c: ' + after.Error__c);
        System.assertEquals('0hard/0medium/-1200soft', after.Score__c);
        System.assertEquals(1, after.Records_Written__c);
        System.assertNotEquals(null, after.Finished__c);
        // The validation result is read even though the solve succeeded: a
        // warning such as TRAVEL_WEIGHT_CONFLICT means the answer is quietly
        // not the one that was asked for.
        System.assertEquals('WARNING', after.Validation_Status__c);
        System.assert(after.Validation_Detail__c.contains('TRAVEL_WEIGHT_CONFLICT'),
            after.Validation_Detail__c);
        System.assertEquals(1, mock.validationCalls,
            'the validation result has to be fetched after a success, not only '
            + 'after a failure');

        Shift written = [SELECT ServiceResourceId, Status FROM Shift
                         WHERE Id = :fixture.shiftId LIMIT 1];
        System.assertEquals(fixture.nurseId, written.ServiceResourceId);
    }

    @IsTest
    static void aRunStillSolvingIsLeftSolving() {
        seed();
        Timefold_Run__c run = startedRun('job-async');
        Test.setMock(HttpCalloutMock.class,
                     new Chatty('SOLVING_SCHEDULED', null, null));
        Test.startTest();
        new TimefoldJob(run.Id, TimefoldJob.Phase.POLL).execute(null);
        Test.stopTest();

        Timefold_Run__c after = [
            SELECT Status__c, Poll_Count__c, Solver_Status__c
            FROM Timefold_Run__c WHERE Id = :run.Id LIMIT 1];
        System.assertEquals('Solving', after.Status__c);
        System.assertEquals(1, after.Poll_Count__c);
        System.assertEquals('SOLVING_SCHEDULED', after.Solver_Status__c);
    }

    @IsTest
    static void aRunThatOutlivesItsPollsSaysWhatToDo() {
        seed();
        Timefold_Run__c run = startedRun('job-async');
        // One short of the cap, so this poll is the last one allowed.
        run.Poll_Count__c = 2;
        update run;
        Test.setMock(HttpCalloutMock.class,
                     new Chatty('SOLVING_SCHEDULED', null, null));
        Test.startTest();
        new TimefoldJob(run.Id, TimefoldJob.Phase.POLL).execute(null);
        Test.stopTest();

        Timefold_Run__c after = [SELECT Status__c, Error__c FROM Timefold_Run__c
                                 WHERE Id = :run.Id LIMIT 1];
        System.assertEquals('Failed', after.Status__c);
        System.assert(after.Error__c.contains('collect'),
            'a run that ran out of polls is not lost, and the message has to '
            + 'say how to pick it up: ' + after.Error__c);
    }

    @IsTest
    static void aRejectedDatasetRecordsWhyBeforeGivingUp() {
        seed();
        Timefold_Run__c run = startedRun('job-async');
        Test.setMock(HttpCalloutMock.class,
                     new Chatty('DATASET_INVALID', null, null));
        Test.startTest();
        new TimefoldJob(run.Id, TimefoldJob.Phase.POLL).execute(null);
        Test.stopTest();

        Timefold_Run__c after = [
            SELECT Status__c, Error__c, Validation_Status__c, Validation_Detail__c
            FROM Timefold_Run__c WHERE Id = :run.Id LIMIT 1];
        System.assertEquals('Failed', after.Status__c);
        System.assert(after.Error__c.contains('DATASET_INVALID'), after.Error__c);
        // DATASET_INVALID says almost nothing on its own. The validation result
        // says which id or tag was actually wrong, so it is read first.
        System.assertNotEquals(null, after.Validation_Status__c,
            'the validation result is the only thing that explains a rejection');
    }

    @IsTest
    static void collectPicksUpARunThatWasLeftBehind() {
        Fixture fixture = seed();
        Timefold_Run__c run = startedRun('job-async');
        Test.setMock(HttpCalloutMock.class,
                     new Chatty('SOLVING_COMPLETED', fixture.shiftId,
                                fixture.nurseName));
        Test.startTest();
        TimefoldJob.collect(run.Id);
        Test.stopTest();
        System.assertEquals('Done',
            [SELECT Status__c FROM Timefold_Run__c WHERE Id = :run.Id].Status__c);
    }

    @IsTest
    static void anOrgWithNoFieldServiceRegionSaysWhichSettingToChange() {
        // A Routes run in an org whose field service region has another name.
        Timefold_Run__c run = new Timefold_Run__c(
            Model__c = 'Routes', Status__c = 'Building', Poll_Count__c = 0);
        insert run;
        Test.startTest();
        new TimefoldJob(run.Id, TimefoldJob.Phase.SUBMIT).execute(null);
        Test.stopTest();
        Timefold_Run__c after = [SELECT Status__c, Error__c FROM Timefold_Run__c
                                 WHERE Id = :run.Id LIMIT 1];
        System.assertEquals('Failed', after.Status__c);
        System.assert(after.Error__c.contains('Routes.RootTerritory'),
            after.Error__c);
    }

    @IsTest
    static void anEmptyOrgSaysToSeedItRatherThanFailingObscurely() {
        Timefold_Run__c run = new Timefold_Run__c(
            Model__c = 'Roster', Status__c = 'Building', Poll_Count__c = 0);
        insert run;
        Test.startTest();
        new TimefoldJob(run.Id, TimefoldJob.Phase.SUBMIT).execute(null);
        Test.stopTest();
        Timefold_Run__c after = [SELECT Status__c, Error__c FROM Timefold_Run__c
                                 WHERE Id = :run.Id LIMIT 1];
        System.assertEquals('Failed', after.Status__c);
        System.assert(after.Error__c.contains('seed'), after.Error__c);
    }

    // ------------------------------------------------------------- the client

    @IsTest
    static void theOtherClientCallsAreExercised() {
        Test.setMock(HttpCalloutMock.class,
                     new Chatty('SOLVING_COMPLETED', 'a', 'b'));
        Test.startTest();
        TimefoldClient.Model model = TimefoldClient.fieldServiceRouting();
        System.assertNotEquals(null, TimefoldClient.fetch(model, 'x'));
        System.assertNotEquals(null, TimefoldClient.validation(model, 'x'));
        TimefoldClient.discard(model, 'x');
        Test.stopTest();
        System.assertEquals('route-plans', model.collection,
            'field service routing keeps its jobs in route-plans, not schedules');
    }

    // --------------------------------------------------------------- the seeder

    @IsTest
    static void theSeederIsIdempotent() {
        Test.startTest();
        TimefoldSeed.Report first = TimefoldSeed.run(7);
        TimefoldSeed.Report second = TimefoldSeed.run(7);
        Test.stopTest();

        System.assertEquals(3, first.wards, first.toString());
        System.assertEquals(first.wards, second.wards,
            'a second run must not double anything');
        System.assertEquals(first.shifts, second.shifts, second.toString());
        System.assert(first.toString().contains('Seeded'), first.toString());
        // Skill records are metadata, not DML: Apex cannot create one even
        // though the REST API can, so a test org has none and the seeder says so.
        System.assert(first.note.contains('Missing Skill') || first.skills > 0,
            'the seeder must either find the skills or say they are missing: '
            + first.note);
    }

    @IsTest
    static void contractHoursAreNormalisedWhicheverPeriodTheOrgAccepted() {
        // ServiceResourceCapacity.TimePeriod has no Weeks in some orgs, so the
        // same 40-hour week arrives as 173 a month or 39.81 a week depending on
        // what the picklist allowed.
        System.assertEquals(173, TimefoldRosterExtract.toMonthlyHours(173, 'Months'));
        System.assertEquals(173, TimefoldRosterExtract.toMonthlyHours(173, 'Month'));
        System.assertEquals(173.33, TimefoldRosterExtract.toMonthlyHours(40, 'Week'));
        System.assertEquals(173.33, TimefoldRosterExtract.toMonthlyHours(40, 'Weeks'));
        System.assertEquals(212.92, TimefoldRosterExtract.toMonthlyHours(7, 'Day'));
        System.assertEquals(null, TimefoldRosterExtract.toMonthlyHours(null, 'Months'));
    }

    // --------------------------------------------- the corners of the model

    @IsTest
    static void aShiftWithNoLabelStillHasAType() {
        // Salesforce has no shift-type field, so the type is the label's last
        // word. A blank label must not take the request down.
        TimefoldRosterExtract.ShiftDemand demand =
            new TimefoldRosterExtract.ShiftDemand();
        System.assertEquals('Shift', demand.shiftType());
        demand.label = '  ICU  Night  ';
        System.assertEquals('Night', demand.shiftType());
        demand.label = 'Day';
        System.assertEquals('Day', demand.shiftType());
    }

    @IsTest
    static void extractReadsAbsencesAndOperatingHoursToo() {
        Fixture fixture = seed();
        // A night pattern, which is two TimeSlots because one cannot cross
        // midnight, plus some leave to plan around.
        Id hoursId = [SELECT OperatingHoursId FROM ServiceTerritoryMember
                      WHERE ServiceResourceId = :fixture.nurseId LIMIT 1]
                     .OperatingHoursId;
        insert new List<TimeSlot>{
            new TimeSlot(OperatingHoursId = hoursId, DayOfWeek = 'Monday',
                         Type = 'Normal',
                         StartTime = Time.newInstance(23, 0, 0, 0),
                         EndTime = Time.newInstance(23, 59, 59, 0)),
            new TimeSlot(OperatingHoursId = hoursId, DayOfWeek = 'Monday',
                         Type = 'Normal',
                         StartTime = Time.newInstance(0, 0, 0, 0),
                         EndTime = Time.newInstance(7, 0, 0, 0))
        };
        insert new ResourceAbsence(
            ResourceId = fixture.nurseId, Type = 'Vacation',
            Start = Datetime.now().addDays(1), End = Datetime.now().addDays(3));
        // Through the seeder's helper, because the valid TimePeriod values
        // differ between orgs and a hardcoded one fails on half of them.
        insert TimefoldSeed.capacityFor(fixture.nurseId, 173);

        Test.startTest();
        TimefoldRosterExtract.Problem problem = TimefoldRosterExtract.run(14);
        Test.stopTest();

        System.assert(!problem.absences.isEmpty(), 'leave should be read');
        System.assert(!problem.operatingHours.isEmpty(), 'hours should be read');
        System.assertEquals(fixture.nurseId,
            problem.nurseById(fixture.nurseId).recordId);
        System.assertEquals(null, problem.nurseById(fixture.shiftId),
            'an id that is not a nurse gives nothing back, not an exception');
        System.assertEquals(173,
            problem.nurseById(fixture.nurseId).capacityHoursPerMonth.round(),
            'whatever unit the org stored, it has to come back as hours a month');

        // And the request builds from real records, not just from a fixture.
        String body = TimefoldRosterRequest.build(problem);
        System.assert(body.contains('unavailableTimeSpans'),
            'leave has to reach Timefold as unavailable time');
    }

    @IsTest
    static void anUnfilledShiftIsClearedRatherThanLeftStale() {
        Fixture fixture = seed();
        // Give the shift somebody first, so clearing it is a real change.
        update new Shift(Id = fixture.shiftId,
                         ServiceResourceId = fixture.nurseId,
                         Status = 'Published');
        TimefoldRosterExtract.Problem problem = TimefoldRosterExtract.run(14);

        Test.startTest();
        TimefoldRosterWriteback.Result result = TimefoldRosterWriteback.apply(
            problem, new Map<String, String>{ String.valueOf(fixture.shiftId) => null });
        Test.stopTest();

        System.assertEquals(1, result.cleared, String.valueOf(result.errors));
        Shift after = [SELECT ServiceResourceId, Status FROM Shift
                       WHERE Id = :fixture.shiftId LIMIT 1];
        System.assertEquals(null, after.ServiceResourceId,
            'a shift the solver could not fill must not keep yesterday\'s nurse');
        System.assertEquals('Tentative', after.Status);
    }

    @IsTest
    static void aSolutionWithNothingUsableIsHandledNotGuessed() {
        System.assertEquals(0,
            TimefoldRosterWriteback.assignmentsFrom(new Map<String, Object>()).size(),
            'no modelOutput at all');
        System.assertEquals(0, TimefoldRosterWriteback.assignmentsFrom(
            new Map<String, Object>{ 'modelOutput' => 'not a map' }).size());
        System.assertEquals(0, TimefoldRosterWriteback.assignmentsFrom(
            new Map<String, Object>{
                'modelOutput' => new Map<String, Object>{
                    'shifts' => 'not a list' } }).size());
    }

    @IsTest
    static void anAssignmentForAShiftOutsideTheWindowIsIgnored() {
        Fixture fixture = seed();
        TimefoldRosterExtract.Problem problem = TimefoldRosterExtract.run(14);
        Test.startTest();
        TimefoldRosterWriteback.Result result = TimefoldRosterWriteback.apply(
            problem, new Map<String, String>{
                String.valueOf(fixture.nurseId) => fixture.nurseName });
        Test.stopTest();
        System.assertEquals(0, result.assigned + result.cleared,
            'an id that is not a shift in this window is not our business');
    }

    // ------------------------------------------------------------------ set-up

    private class Fixture {
        public Id nurseId;
        public String nurseName;
        public Id shiftId;
    }

    private static Fixture seed() {
        OperatingHours hours = new OperatingHours(
            Name = 'Test hours', TimeZone = 'Europe/London');
        insert hours;
        ServiceTerritory ward = new ServiceTerritory(
            Name = 'St. Elmore ICU', OperatingHoursId = hours.Id, IsActive = true);
        insert ward;
        ServiceResource nurse = new ServiceResource(
            Name = 'Amara Okafor', ResourceType = 'T', IsActive = true,
            IsCapacityBased = true, RelatedRecordId = UserInfo.getUserId());
        insert nurse;
        insert new ServiceTerritoryMember(
            ServiceResourceId = nurse.Id, ServiceTerritoryId = ward.Id,
            TerritoryType = 'P', OperatingHoursId = hours.Id,
            EffectiveStartDate = Datetime.now().addDays(-7));
        Shift shift = new Shift(
            ServiceTerritoryId = ward.Id, Label = 'ICU Day',
            StartTime = Datetime.now().addDays(1),
            EndTime = Datetime.now().addDays(1).addHours(8),
            Status = 'Tentative');
        insert shift;

        Fixture fixture = new Fixture();
        fixture.nurseId = nurse.Id;
        fixture.nurseName = nurse.Name;
        fixture.shiftId = shift.Id;
        return fixture;
    }

    private static Timefold_Run__c startedRun(String jobId) {
        Timefold_Run__c run = new Timefold_Run__c(
            Model__c = 'Roster', Status__c = 'Submitted',
            Timefold_Job_Id__c = jobId, Poll_Count__c = 0);
        insert run;
        return run;
    }
}
