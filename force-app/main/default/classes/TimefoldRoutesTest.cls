/**
 * The routing half: read the round, build the request, write the plan back.
 *
 * The extract is tested against real records, because its whole job is SOQL.
 * The request and the write-back are tested against hand-built Problem objects
 * instead: that is the only way to cover skills and tags, since Skill is a
 * setup object that Apex cannot insert, and it keeps the assertions about the
 * JSON rather than about the fixture.
 */
@IsTest
private class TimefoldRoutesTest {

    /** A Monday, so every weekday assertion below is deterministic. */
    private static final Datetime MONDAY =
        Datetime.newInstanceGmt(2026, 9, 7, 8, 0, 0);

    private class Fixture {
        Id regionId;
        Id engineerId;
        String engineerName;
        Id appointmentId;
    }

    // --------------------------------------------------------------- extract

    @IsTest
    static void theExtractReadsTheRegionSubtreeAndItsWork() {
        Fixture fixture = seed();

        Test.startTest();
        TimefoldRoutesExtract.Problem problem = TimefoldRoutesExtract.run(3);
        Test.stopTest();

        // The root and the region under it, both in scope: one root name is
        // enough however many regions hang off it.
        System.assertEquals(2, problem.regions.size(),
            'expected the root territory and its child: ' + problem.regions.values());
        System.assertEquals(Datetime.newInstanceGmt(2026, 9, 7, 0, 0, 0),
            problem.windowStart, 'the window starts at midnight of the first job');
        System.assertEquals(Datetime.newInstanceGmt(2026, 9, 10, 0, 0, 0),
            problem.windowEnd);

        System.assertEquals(1, problem.visits.size());
        TimefoldRoutesExtract.Visit visit = problem.visits[0];
        System.assertEquals(fixture.appointmentId, visit.recordId);
        System.assertEquals(45, visit.durationMinutes);
        System.assertEquals('London North', visit.region);
        System.assertEquals(51.5, visit.latitude);

        System.assertEquals(1, problem.technicians.size());
        TimefoldRoutesExtract.Technician tech = problem.technicians[0];
        System.assertEquals(fixture.engineerId, tech.recordId);
        System.assertEquals('London North', tech.region);
        // The membership is the home base, not ServiceResource.LastKnownLatitude:
        // that field is wherever the mobile app last saw them.
        System.assertEquals(51.58, tech.homeLatitude);
        System.assert(tech.hasHome());
        System.assertEquals(5, problem.operatingHours.get(tech.operatingHoursId).size(),
            'Monday to Friday');
    }

    @IsTest
    static void anAppointmentWithNoCoordinatesIsCountedNotRouted() {
        Fixture fixture = seed();
        // The parent WorkOrder is not optional here: FSL's own
        // TR001_Service_BeforeInsert trigger dereferences it and throws a
        // NullPointerException on a standalone appointment.
        WorkOrder order = new WorkOrder(ServiceTerritoryId = fixture.regionId);
        insert order;
        insert new ServiceAppointment(
            ParentRecordId = order.Id, ServiceTerritoryId = fixture.regionId,
            EarliestStartTime = MONDAY, DueDate = MONDAY.addHours(8),
            Duration = 30, DurationType = 'Minutes', Status = 'None');

        Test.startTest();
        TimefoldRoutesExtract.Problem problem = TimefoldRoutesExtract.run(3);
        Test.stopTest();

        System.assertEquals(1, problem.visits.size(),
            'the one without coordinates must not be routed');
        System.assertEquals(1, problem.visitsWithoutCoordinates,
            'but it has to be counted, or a plan silently covers less than it claims');
    }

    @IsTest
    static void anExistingAssignmentIsRead() {
        Fixture fixture = seed();
        // Field Service refuses an AssignedResource on an unscheduled
        // appointment - "Service Appointment missing schedule time on insert
        // or update of Assign Resource" - which is why the write-back updates
        // the appointments before it inserts the links.
        update new ServiceAppointment(
            Id = fixture.appointmentId, SchedStartTime = MONDAY,
            SchedEndTime = MONDAY.addHours(1), Status = 'Scheduled');
        insert new AssignedResource(
            ServiceAppointmentId = fixture.appointmentId,
            ServiceResourceId = fixture.engineerId);

        Test.startTest();
        TimefoldRoutesExtract.Problem problem = TimefoldRoutesExtract.run(3);
        Test.stopTest();

        System.assert(problem.visits[0].assignedResourceIds
                          .contains(fixture.engineerId),
            'the write-back needs this, or a re-plan creates a duplicate link');
    }

    @IsTest
    static void aMissingRootTerritorySaysSo() {
        // No records at all, so the configured root does not exist.
        Test.startTest();
        try {
            TimefoldRoutesExtract.run(3);
            System.assert(false, 'expected a refusal');
        } catch (TimefoldClient.TimefoldException e) {
            System.assert(e.getMessage().contains('St. Elmore Field Service'),
                e.getMessage());
            System.assert(e.getMessage().contains('Routes.RootTerritory'),
                'the message has to name the setting that fixes it: ' + e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void aRegionWithNoWorkSaysSo() {
        OperatingHours hours = new OperatingHours(
            Name = 'Field service 08:00-17:00', TimeZone = 'Europe/London');
        insert hours;
        insert new ServiceTerritory(Name = 'St. Elmore Field Service',
                                    OperatingHoursId = hours.Id, IsActive = true);
        Test.startTest();
        try {
            TimefoldRoutesExtract.run(3);
            System.assert(false, 'expected a refusal');
        } catch (TimefoldClient.TimefoldException e) {
            System.assert(e.getMessage().contains('no ServiceAppointment'),
                e.getMessage());
        }
        Test.stopTest();
    }

    @IsTest
    static void durationsAreReadInWhicheverUnitTheOrgUsed() {
        System.assertEquals(90, TimefoldRoutesExtract.toMinutes(90, 'Minutes'));
        System.assertEquals(90, TimefoldRoutesExtract.toMinutes(1.5, 'Hours'));
        System.assertEquals(60, TimefoldRoutesExtract.toMinutes(null, null),
            'a missing duration is an hour, not zero: zero would let the solver '
            + 'stack every job on one engineer');
    }

    // --------------------------------------------------------------- request

    @IsTest
    static void theRequestCarriesOneShiftPerWorkingDay() {
        TimefoldRoutesExtract.Problem problem = handBuilt();
        TimefoldRoutesRequest.Notes notes = new TimefoldRoutesRequest.Notes();

        String body = TimefoldRoutesRequest.build(problem, notes);
        Map<String, Object> sent =
            (Map<String, Object>) JSON.deserializeUntyped(body);
        Map<String, Object> input = (Map<String, Object>) sent.get('modelInput');

        System.assertEquals(1, notes.vehicles);
        System.assertEquals(3, notes.shifts, 'Monday, Tuesday, Wednesday');
        System.assertEquals(1, notes.visits);

        List<Object> vehicles = (List<Object>) input.get('vehicles');
        System.assertEquals(1, vehicles.size());
        Map<String, Object> vehicle = (Map<String, Object>) vehicles[0];
        System.assertEquals('Nadia Rahimi', vehicle.get('id'),
            'the id is the resource Name, which is how the write-back finds them again');
        List<Object> shifts = (List<Object>) vehicle.get('shifts');
        System.assertEquals(3, shifts.size());

        Map<String, Object> shift = (Map<String, Object>) shifts[0];
        System.assertEquals('2026-09-07T08:00:00Z', shift.get('minStartTime'));
        System.assertEquals('2026-09-07T17:00:00Z', shift.get('maxSoftEndTime'));
        // The rostered end is soft, the overtime allowance hard.
        System.assertEquals('2026-09-07T17:30:00Z', shift.get('maxEndTime'));
        System.assertNotEquals(null, shift.get('endLocation'),
            'Routes.ReturnToHome is on by default');
        System.assertEquals(new List<Object>{ 'London North' }, shift.get('tags'));

        // Field Service Routing spells the window startDate/endDate, where the
        // roster model says start/end. Getting this wrong is a silent
        // DATASET_INVALID.
        Map<String, Object> window =
            (Map<String, Object>) input.get('planningWindow');
        System.assertEquals('2026-09-07T00:00:00Z', window.get('startDate'));
        System.assertEquals('2026-09-10T00:00:00Z', window.get('endDate'));
    }

    @IsTest
    static void everyTagAndSkillIsDeclaredUpFront() {
        TimefoldRoutesExtract.Problem problem = handBuilt();
        Map<String, Object> input = (Map<String, Object>)
            ((Map<String, Object>) JSON.deserializeUntyped(
                TimefoldRoutesRequest.build(problem))).get('modelInput');

        // An undeclared tag or skill is not a warning: the run comes back
        // DATASET_INVALID.
        System.assertEquals(new List<Object>{
            new Map<String, Object>{ 'name' => 'London North' } },
            input.get('tags'), 'a tag is an object with a name here');
        System.assertEquals(new List<Object>{ 'Infusion Pumps' },
            input.get('skills'), 'but a declared skill is a bare string');

        Map<String, Object> visit =
            (Map<String, Object>) ((List<Object>) input.get('visits'))[0];
        System.assertEquals(new List<Object>{ 'London North' },
            visit.get('requiredTags'));
        System.assertEquals('PT45M', visit.get('serviceDuration'));
        Map<String, Object> required = (Map<String, Object>)
            ((List<Object>) visit.get('requiredSkills'))[0];
        System.assertEquals('Infusion Pumps', required.get('name'));
        System.assertEquals(3, required.get('minLevel'));

        Map<String, Object> vehicleShift = (Map<String, Object>)
            ((List<Object>) ((Map<String, Object>)
                ((List<Object>) input.get('vehicles'))[0]).get('shifts'))[0];
        Map<String, Object> held = (Map<String, Object>)
            ((List<Object>) vehicleShift.get('skills'))[0];
        System.assertEquals('Infusion Pumps', held.get('name'));
        System.assertEquals(5, held.get('level'),
            'a vehicle shift holds a level; a visit demands a minLevel');
    }

    @IsTest
    static void anEngineerWithNoHomeBaseIsLeftOutAndNamed() {
        TimefoldRoutesExtract.Problem problem = handBuilt();
        TimefoldRoutesExtract.Technician homeless =
            new TimefoldRoutesExtract.Technician();
        homeless.recordId = problem.technicians[0].recordId;
        homeless.name = 'Priyanka Shah';
        homeless.region = 'London North';
        problem.technicians.add(homeless);

        TimefoldRoutesRequest.Notes notes = new TimefoldRoutesRequest.Notes();
        TimefoldRoutesRequest.build(problem, notes);

        System.assertEquals(1, notes.vehicles);
        System.assertEquals(new List<String>{ 'Priyanka Shah' },
            notes.engineersWithoutHome,
            'a made-up starting point would give a plausible plan with wrong '
            + 'travel times, so it has to be reported instead');
    }

    @IsTest
    static void withNoOperatingHoursTheFallbackSkipsTheWeekend() {
        TimefoldRoutesExtract.Problem problem = handBuilt();
        problem.operatingHours.clear();
        problem.windowEnd = problem.windowStart.addDays(7);

        TimefoldRoutesRequest.Notes notes = new TimefoldRoutesRequest.Notes();
        TimefoldRoutesRequest.build(problem, notes);

        System.assertEquals(5, notes.shifts,
            'five working days out of seven; without the day list the solver '
            + 'books a Sunday quite happily');
    }

    @IsTest
    static void weekdaysAreCountedNotFormatted() {
        // Datetime.format('EEEE') would answer in the running user's locale,
        // and TimeSlot.DayOfWeek is always English.
        System.assertEquals('Monday',
            TimefoldRoutesRequest.weekdayOf(MONDAY));
        System.assertEquals('Sunday',
            TimefoldRoutesRequest.weekdayOf(MONDAY.addDays(6)));
        System.assertEquals('Wednesday',
            TimefoldRoutesRequest.weekdayOf(
                Datetime.newInstanceGmt(2023, 6, 14, 9, 0, 0)),
            'a date before the reference Monday must not index the list backwards');
    }

    // ------------------------------------------------------------- writeback

    @IsTest
    static void aSolvedRouteIsFlattenedIntoStops() {
        Map<String, Object> response = solvedRoute('Nadia Rahimi', 'visit-1');
        List<TimefoldRoutesWriteback.Stop> stops =
            TimefoldRoutesWriteback.stopsFrom(response);

        System.assertEquals(1, stops.size(),
            'the BREAK item in the itinerary is not an appointment');
        TimefoldRoutesWriteback.Stop stop = stops[0];
        System.assertEquals('visit-1', stop.visitId);
        System.assertEquals('Nadia Rahimi', stop.engineer);
        System.assertEquals(Datetime.newInstanceGmt(2026, 9, 7, 9, 15, 0),
            stop.startService);
        System.assertEquals(Datetime.newInstanceGmt(2026, 9, 7, 10, 0, 0),
            stop.departure);
        System.assertEquals(4200, stop.travelMetersFromPrevious);
        System.assertEquals(new List<String>{ 'visit-2' },
            TimefoldRoutesWriteback.unassignedFrom(response));
    }

    @IsTest
    static void thePlanLandsOnTheStandardFieldsAndTidiesStaleLinks() {
        Fixture fixture = seed();
        // A link to somebody the new plan does not keep. Left behind, the
        // appointment shows on two engineers' rows in the Gantt.
        //
        // A second User is needed, because ServiceResource.RelatedRecordId is
        // unique: two resources cannot point at one person. User is visible in
        // a test without SeeAllData, and every org has more than one.
        ServiceResource other = new ServiceResource(
            Name = 'Priyanka Shah', ResourceType = 'T', IsActive = true,
            RelatedRecordId = spareUser());
        insert other;
        // She also has to be a member of the appointment's territory, or Field
        // Service refuses the link: "We couldn't schedule the service
        // appointment because there's no service territory member defined."
        insert new ServiceTerritoryMember(
            ServiceResourceId = other.Id, ServiceTerritoryId = fixture.regionId,
            TerritoryType = 'S', EffectiveStartDate = MONDAY.addDays(-30));
        // And a link needs a scheduled appointment, so give it a time first.
        update new ServiceAppointment(
            Id = fixture.appointmentId, SchedStartTime = MONDAY,
            SchedEndTime = MONDAY.addHours(1), Status = 'Scheduled');
        insert new AssignedResource(
            ServiceAppointmentId = fixture.appointmentId,
            ServiceResourceId = other.Id);

        TimefoldRoutesExtract.Problem problem = TimefoldRoutesExtract.run(3);
        List<TimefoldRoutesWriteback.Stop> stops =
            TimefoldRoutesWriteback.stopsFrom(
                solvedRoute(fixture.engineerName, fixture.appointmentId));

        Test.startTest();
        TimefoldRoutesWriteback.Result result = TimefoldRoutesWriteback.apply(
            problem, stops, new List<String>());
        Test.stopTest();

        System.assertEquals(1, result.scheduled, String.join(result.errors, '; '));
        System.assertEquals(1, result.linksCreated);
        System.assertEquals(1, result.linksRemoved);
        System.assert(result.errors.isEmpty(), String.join(result.errors, '; '));

        ServiceAppointment written = [
            SELECT Status, SchedStartTime, SchedEndTime FROM ServiceAppointment
            WHERE Id = :fixture.appointmentId LIMIT 1];
        System.assertEquals('Scheduled', written.Status);
        System.assertEquals(Datetime.newInstanceGmt(2026, 9, 7, 9, 15, 0),
            written.SchedStartTime);
        System.assertEquals(Datetime.newInstanceGmt(2026, 9, 7, 10, 0, 0),
            written.SchedEndTime);

        List<AssignedResource> links = [
            SELECT ServiceResourceId FROM AssignedResource
            WHERE ServiceAppointmentId = :fixture.appointmentId];
        System.assertEquals(1, links.size(), 'the stale link had to go');
        System.assertEquals(fixture.engineerId, links[0].ServiceResourceId);
    }

    @IsTest
    static void anUnassignedVisitIsCleared() {
        Fixture fixture = seed();
        update new ServiceAppointment(
            Id = fixture.appointmentId, Status = 'Scheduled',
            SchedStartTime = MONDAY, SchedEndTime = MONDAY.addHours(1));

        TimefoldRoutesExtract.Problem problem = TimefoldRoutesExtract.run(3);
        Test.startTest();
        TimefoldRoutesWriteback.Result result = TimefoldRoutesWriteback.apply(
            problem, new List<TimefoldRoutesWriteback.Stop>(),
            new List<String>{ fixture.appointmentId });
        Test.stopTest();

        System.assertEquals(1, result.unscheduled);
        ServiceAppointment cleared = [
            SELECT Status, SchedStartTime FROM ServiceAppointment
            WHERE Id = :fixture.appointmentId LIMIT 1];
        System.assertEquals('None', cleared.Status);
        System.assertEquals(null, cleared.SchedStartTime,
            'a visit the solver could not place must not keep its old time');
    }

    @IsTest
    static void anEngineerTimefoldNamedButTheOrgLacksIsReported() {
        Fixture fixture = seed();
        TimefoldRoutesExtract.Problem problem = TimefoldRoutesExtract.run(3);
        List<TimefoldRoutesWriteback.Stop> stops =
            TimefoldRoutesWriteback.stopsFrom(
                solvedRoute('Somebody Else', fixture.appointmentId));

        Test.startTest();
        TimefoldRoutesWriteback.Result result = TimefoldRoutesWriteback.apply(
            problem, stops, new List<String>());
        Test.stopTest();

        System.assertEquals(0, result.scheduled);
        System.assert(result.unknownEngineers.contains('Somebody Else'),
            'silently dropping it would look like an unroutable job');
    }

    @IsTest
    static void twoEngineersWithOneNameAreRefusedNotGuessed() {
        Fixture fixture = seed();
        TimefoldRoutesExtract.Problem problem = TimefoldRoutesExtract.run(3);
        TimefoldRoutesExtract.Technician twin =
            new TimefoldRoutesExtract.Technician();
        twin.recordId = fixture.engineerId;
        twin.name = fixture.engineerName;
        problem.technicians.add(twin);

        List<TimefoldRoutesWriteback.Stop> stops =
            TimefoldRoutesWriteback.stopsFrom(
                solvedRoute(fixture.engineerName, fixture.appointmentId));

        Test.startTest();
        TimefoldRoutesWriteback.Result result =
            TimefoldRoutesWriteback.apply(problem, stops, new List<String>());
        Test.stopTest();

        System.assertEquals(0, result.scheduled,
            'picking either one would attach the work to the wrong person and '
            + 'read as a solver mistake');
        System.assertEquals(1, result.unknownEngineers.size(),
            String.join(new List<String>(result.unknownEngineers), '; '));
    }

    @IsTest
    static void timefoldTimestampsAreRead() {
        System.assertEquals(Datetime.newInstanceGmt(2026, 9, 2, 9, 15, 0),
            TimefoldRoutesWriteback.parse('2026-09-02T09:15:00Z'));
        System.assertEquals(Datetime.newInstanceGmt(2026, 9, 2, 9, 15, 0),
            TimefoldRoutesWriteback.parse('2026-09-02T09:15:00.000Z'),
            'fractional seconds appear on some endpoints');
        System.assertEquals(null, TimefoldRoutesWriteback.parse(null));
    }

    // ---------------------------------------------------------- the whole run

    /** Answers a routing run: submit, metadata, solution, validation. */
    private class Router implements HttpCalloutMock {
        private final String engineer;
        private final String visitId;
        Router(String engineer, String visitId) {
            this.engineer = engineer;
            this.visitId = visitId;
        }
        public HttpResponse respond(HttpRequest request) {
            HttpResponse reply = new HttpResponse();
            reply.setStatusCode(200);
            String endpoint = request.getEndpoint();
            System.assert(endpoint.contains('/field-service-routing/'),
                'a Routes run must not be sent to the roster model: ' + endpoint);
            if (endpoint.endsWith('/metadata')) {
                reply.setBody(JSON.serialize(new Map<String, Object>{
                    'solverStatus' => 'SOLVING_COMPLETED',
                    'score' => '0hard/0medium/-989783soft' }));
            } else if (endpoint.endsWith('/validation-result')) {
                reply.setBody(JSON.serialize(
                    new Map<String, Object>{ 'status' => 'OK' }));
            } else if (request.getMethod() == 'POST') {
                reply.setBody('"route-job"');
            } else {
                Map<String, Object> solution = solvedRoute(engineer, visitId);
                solution.put('score', '0hard/0medium/-989783soft');
                solution.put('kpis', new Map<String, Object>{
                    'totalTravelTime' => 'PT5H6M36S',
                    'totalTravelDistanceMeters' => 170430 });
                reply.setBody(JSON.serialize(solution));
            }
            return reply;
        }
    }

    @IsTest
    static void submitSendsTheRoundToTheRoutingModel() {
        seed();
        Timefold_Run__c run = new Timefold_Run__c(
            Model__c = 'Routes', Status__c = 'Building', Poll_Count__c = 0);
        insert run;
        Test.setMock(HttpCalloutMock.class, new Router('Nadia Rahimi', 'x'));

        Test.startTest();
        new TimefoldJob(run.Id, TimefoldJob.Phase.SUBMIT).execute(null);
        Test.stopTest();

        Timefold_Run__c after = [
            SELECT Status__c, Timefold_Job_Id__c, Records_Planned__c,
                   Window_Start__c, Error__c
            FROM Timefold_Run__c WHERE Id = :run.Id LIMIT 1];
        // A null third argument makes System.assertEquals throw
        // "Argument 3 cannot be null", which hides the real failure.
        System.assertEquals('Submitted', after.Status__c,
                            'Error__c: ' + after.Error__c);
        System.assertEquals('route-job', after.Timefold_Job_Id__c);
        System.assertEquals(1, after.Records_Planned__c);
        System.assertEquals(Datetime.newInstanceGmt(2026, 9, 7, 0, 0, 0),
            after.Window_Start__c);
    }

    @IsTest
    static void aFinishedRoutingRunRecordsTheDrivingItSaved() {
        Fixture fixture = seed();
        Timefold_Run__c run = new Timefold_Run__c(
            Model__c = 'Routes', Status__c = 'Submitted',
            Timefold_Job_Id__c = 'route-job', Poll_Count__c = 0);
        insert run;
        Test.setMock(HttpCalloutMock.class,
                     new Router(fixture.engineerName, fixture.appointmentId));

        Test.startTest();
        new TimefoldJob(run.Id, TimefoldJob.Phase.POLL).execute(null);
        Test.stopTest();

        Timefold_Run__c after = [
            SELECT Status__c, Score__c, Records_Written__c, Unassigned__c,
                   Travel_Time_Hours__c, Travel_Distance_Km__c,
                   Validation_Status__c, Error__c
            FROM Timefold_Run__c WHERE Id = :run.Id LIMIT 1];
        System.assertEquals('Done', after.Status__c,
                            'Error__c: ' + after.Error__c);
        System.assertEquals('0hard/0medium/-989783soft', after.Score__c);
        System.assertEquals(1, after.Records_Written__c);
        System.assertEquals(1, after.Unassigned__c, 'visit-2 came back unassigned');
        // The one number that shows the routing is real: these are OSRM road
        // distances from the platform's maps service, not straight lines.
        System.assertEquals(5.11, after.Travel_Time_Hours__c);
        System.assertEquals(170.4, after.Travel_Distance_Km__c);
        System.assertEquals('OK', after.Validation_Status__c);

        ServiceAppointment written = [
            SELECT Status FROM ServiceAppointment
            WHERE Id = :fixture.appointmentId LIMIT 1];
        System.assertEquals('Scheduled', written.Status);
    }

    @IsTest
    static void isoDurationsAreReadAsHours() {
        System.assertEquals(5.11, TimefoldJob.hoursFrom('PT5H6M36S').setScale(2));
        System.assertEquals(26, TimefoldJob.hoursFrom('P1DT2H'));
        System.assertEquals(0.5, TimefoldJob.hoursFrom('PT30M'));
        System.assertEquals(null, TimefoldJob.hoursFrom(null));
        System.assertEquals(null, TimefoldJob.hoursFrom('half an hour'));
    }

    // ---------------------------------------------------------------- breaks

    @IsTest
    static void leaveInsideAShiftBecomesAFixedBreak() {
        TimefoldRoutesExtract.Problem problem = handBuilt();
        addLeave(problem, 12, 0, 12, 30);

        TimefoldRoutesRequest.Notes notes = new TimefoldRoutesRequest.Notes();
        Map<String, Object> shift = firstShift(
            TimefoldRoutesRequest.build(problem, notes));

        System.assertEquals(1, notes.breaks);
        List<Object> breaks = (List<Object>) shift.get('requiredBreaks');
        System.assertEquals(1, breaks.size());
        Map<String, Object> lunch = (Map<String, Object>) breaks[0];
        // FIXED of the three shapes the schema offers: a ResourceAbsence has a
        // definite start and end, where FLOATING means "half an hour somewhere
        // in the middle" and LEGACY is deprecated.
        System.assertEquals('FIXED', lunch.get('type'));
        System.assertEquals('2026-09-07T12:00:00Z', lunch.get('startTime'));
        System.assertEquals('2026-09-07T12:30:00Z', lunch.get('endTime'));
        System.assertNotEquals(null, lunch.get('id'), 'a break needs an id');
    }

    @IsTest
    static void leaveOverlappingTheEdgeOfAShiftIsClipped() {
        TimefoldRoutesExtract.Problem problem = handBuilt();
        addLeave(problem, 6, 0, 9, 0);          // starts before the shift does

        Map<String, Object> shift = firstShift(
            TimefoldRoutesRequest.build(problem));
        Map<String, Object> lunch = (Map<String, Object>)
            ((List<Object>) shift.get('requiredBreaks'))[0];
        System.assertEquals('2026-09-07T08:00:00Z', lunch.get('startTime'),
            'a break that starts before its shift is a validation issue of its own');
        System.assertEquals('2026-09-07T09:00:00Z', lunch.get('endTime'));
    }

    @IsTest
    static void aWholeDayOffDropsTheShiftRatherThanFillingIt() {
        TimefoldRoutesExtract.Problem problem = handBuilt();
        addLeave(problem, 0, 0, 23, 59);

        TimefoldRoutesRequest.Notes notes = new TimefoldRoutesRequest.Notes();
        TimefoldRoutesRequest.build(problem, notes);

        System.assertEquals(2, notes.shifts, 'the first of three days is gone');
        System.assertEquals(1, notes.shiftsDroppedForLeave,
            'a shift with a break across all of it is a different statement: '
            + 'the vehicle still counts as activated and can be given travel');
    }

    @IsTest
    static void breaksCanBeSwitchedOff() {
        insert new Timefold_Setting__c(
            Name = 'Routes.BreaksFromAbsences', Value__c = 'false');
        TimefoldRules.reset();

        TimefoldRoutesExtract.Problem problem = handBuilt();
        addLeave(problem, 12, 0, 12, 30);
        TimefoldRoutesRequest.Notes notes = new TimefoldRoutesRequest.Notes();
        Map<String, Object> shift = firstShift(
            TimefoldRoutesRequest.build(problem, notes));

        System.assertEquals(0, notes.breaks);
        System.assertEquals(null, shift.get('requiredBreaks'));
    }

    // ------------------------------------------------------------------- pins

    @IsTest
    static void aDispatchedJobIsPinnedBecauseItIsAlreadyWithAnEngineer() {
        Fixture fixture = seed();
        commitByHand(fixture, MONDAY.addHours(1), 'Dispatched');

        Test.startTest();
        TimefoldRoutesExtract.Problem problem = TimefoldRoutesExtract.run(3);
        Test.stopTest();

        System.assertEquals(1, problem.pinnedVisits().size(),
            'a dispatched job is not a planning decision any more');
        System.assert(problem.visits[0].pinReason.contains('Dispatched'),
            problem.visits[0].pinReason);
    }

    @IsTest
    static void aCancelledJobIsLeftOutOfTheProblemEntirely() {
        Fixture fixture = seed();
        update new ServiceAppointment(
            Id = fixture.appointmentId, Status = 'Canceled');

        Test.startTest();
        TimefoldRoutesExtract.Problem problem = TimefoldRoutesExtract.run(3);
        Test.stopTest();

        System.assertEquals(0, problem.visits.size(),
            'a cancelled job is not work, so it is left out rather than pinned');
        System.assertEquals(1, problem.visitsCancelled);
    }

    @IsTest
    static void aHandScheduledJobIsToldApartFromTheSolversOwn() {
        Fixture fixture = seed();
        Datetime whenever = MONDAY.addHours(1);
        commitByHand(fixture, whenever, 'Scheduled');
        // A finished run that placed this visit somewhere else. The current
        // placement therefore is not one Timefold made.
        recordPlan(TimefoldRoutesExtract.placementOf(
            fixture.appointmentId, fixture.engineerId, MONDAY.addHours(5)));

        Test.startTest();
        TimefoldRoutesExtract.Problem problem = TimefoldRoutesExtract.run(3);
        Test.stopTest();

        System.assertEquals(1, problem.pinnedVisits().size(),
            'this placement is in no recorded plan, so a person made it');
        System.assert(problem.visits[0].pinReason.contains('by hand'),
            problem.visits[0].pinReason);
    }

    @IsTest
    static void theSolversOwnPlacementIsNotMistakenForAManualOne() {
        Fixture fixture = seed();
        Datetime whenever = MONDAY.addHours(1);
        commitByHand(fixture, whenever, 'Scheduled');
        recordPlan(TimefoldRoutesExtract.placementOf(
            fixture.appointmentId, fixture.engineerId, whenever));

        Test.startTest();
        TimefoldRoutesExtract.Problem problem = TimefoldRoutesExtract.run(3);
        Test.stopTest();

        System.assertEquals(0, problem.pinnedVisits().size(),
            'Timefold put it there itself, so it stays free to move it again');
    }

    @IsTest
    static void withNoRecordedPlanNothingIsPinnedByProvenance() {
        Fixture fixture = seed();
        commitByHand(fixture, MONDAY.addHours(1), 'Scheduled');

        Test.startTest();
        TimefoldRoutesExtract.Problem problem = TimefoldRoutesExtract.run(3);
        Test.stopTest();

        // Otherwise an org whose appointments were scheduled by Salesforce's
        // own optimiser before Timefold ever ran would arrive completely
        // pinned, and the very first run could change nothing at all.
        System.assertEquals(0, problem.pinnedVisits().size(),
            'with no plan on record the provenance signal has nothing to say');
    }

    @IsTest
    static void respectExistingCanBeSwitchedOff() {
        Fixture fixture = seed();
        commitByHand(fixture, MONDAY.addHours(1), 'Dispatched');
        insert new Timefold_Setting__c(
            Name = 'Routes.RespectExisting', Value__c = 'false');
        TimefoldRules.reset();

        Test.startTest();
        TimefoldRoutesExtract.Problem problem = TimefoldRoutesExtract.run(3);
        Test.stopTest();

        System.assertEquals(0, problem.pinnedVisits().size(),
            'one setting turns the whole thing off');
    }

    @IsTest
    static void aPinnedVisitGoesIntoItsShiftItineraryAndLosesItsWindow() {
        TimefoldRoutesExtract.Problem problem = handBuilt();
        pin(problem.visits[0], problem.technicians[0],
            Datetime.newInstanceGmt(2026, 9, 7, 9, 15, 0));

        TimefoldRoutesRequest.Notes notes = new TimefoldRoutesRequest.Notes();
        String body = TimefoldRoutesRequest.build(problem, notes);
        Map<String, Object> input = (Map<String, Object>)
            ((Map<String, Object>) JSON.deserializeUntyped(body)).get('modelInput');

        System.assertEquals(1, notes.pinned);
        System.assert(notes.pinsDropped.isEmpty(),
            String.join(notes.pinsDropped, '; '));

        Map<String, Object> shift = firstShift(body);
        List<Object> itinerary = (List<Object>) shift.get('itinerary');
        System.assertEquals(1, itinerary.size(),
            'a pin the model can honour has to be on the shift, not only on '
            + 'the visit, or the run is DATASET_INVALID');
        Map<String, Object> stop = (Map<String, Object>) itinerary[0];
        System.assertEquals('VISIT', stop.get('kind'));
        System.assertEquals(true, stop.get('pin'));
        System.assertEquals('2026-09-07T09:15:00Z', stop.get('startServiceTime'));

        Map<String, Object> visit =
            (Map<String, Object>) ((List<Object>) input.get('visits'))[0];
        System.assertEquals(true, visit.get('pinningRequested'));
        // Not being planned, being told: a customer window that contradicts
        // the time a person chose would invalidate the dataset rather than
        // override the person.
        System.assertEquals(null, visit.get('timeWindows'),
            'a pinned visit is sent without its time window');
    }

    @IsTest
    static void pinsOnOneShiftAreSentInChronologicalOrder() {
        TimefoldRoutesExtract.Problem problem = handBuilt();
        TimefoldRoutesExtract.Visit later = secondVisit(problem);
        pin(later, problem.technicians[0],
            Datetime.newInstanceGmt(2026, 9, 7, 14, 0, 0));
        pin(problem.visits[0], problem.technicians[0],
            Datetime.newInstanceGmt(2026, 9, 7, 9, 15, 0));

        Map<String, Object> shift = firstShift(
            TimefoldRoutesRequest.build(problem));
        List<Object> itinerary = (List<Object>) shift.get('itinerary');
        System.assertEquals(2, itinerary.size());
        // "In case multiple visits on an itinerary are pinned, they need to be
        // chronologically sorted by their startServiceTime."
        System.assertEquals('2026-09-07T09:15:00Z',
            ((Map<String, Object>) itinerary[0]).get('startServiceTime'));
        System.assertEquals('2026-09-07T14:00:00Z',
            ((Map<String, Object>) itinerary[1]).get('startServiceTime'));
    }

    @IsTest
    static void aPinNoShiftCanHoldIsReportedNotSilentlyDropped() {
        TimefoldRoutesExtract.Problem problem = handBuilt();
        // 22:00, long after the shift's hard end.
        pin(problem.visits[0], problem.technicians[0],
            Datetime.newInstanceGmt(2026, 9, 7, 22, 0, 0));

        TimefoldRoutesRequest.Notes notes = new TimefoldRoutesRequest.Notes();
        String body = TimefoldRoutesRequest.build(problem, notes);

        System.assertEquals(0, notes.pinned);
        System.assertEquals(1, notes.pinsDropped.size(),
            'unpinning a job a dispatcher committed to without saying so is '
            + 'the worst of the three options');
        Map<String, Object> input = (Map<String, Object>)
            ((Map<String, Object>) JSON.deserializeUntyped(body)).get('modelInput');
        Map<String, Object> visit =
            (Map<String, Object>) ((List<Object>) input.get('visits'))[0];
        System.assertEquals(null, visit.get('pinningRequested'),
            'telling the model a visit is pinned with no itinerary item to '
            + 'match is DATASET_INVALID');
    }

    @IsTest
    static void theWriteBackLeavesAPinnedVisitAloneButKeepsItsLink() {
        Fixture fixture = seed();
        Datetime byHand = MONDAY.addHours(1);
        commitByHand(fixture, byHand, 'Dispatched');

        TimefoldRoutesExtract.Problem problem = TimefoldRoutesExtract.run(3);
        System.assertEquals(1, problem.pinnedVisits().size(), 'fixture check');
        // The solver echoed the pin back, as it must.
        List<TimefoldRoutesWriteback.Stop> stops =
            TimefoldRoutesWriteback.stopsFrom(
                solvedRoute(fixture.engineerName, fixture.appointmentId));

        Test.startTest();
        TimefoldRoutesWriteback.Result result =
            TimefoldRoutesWriteback.apply(problem, stops, new List<String>());
        Test.stopTest();

        System.assertEquals(1, result.leftPinned);
        System.assertEquals(0, result.scheduled);
        System.assertEquals(0, result.linksRemoved,
            'deleting the very assignment that was pinned would be a '
            + 'spectacular way to honour a pin');
        System.assertEquals(null, result.signatureText(),
            'a pinned visit was a person\'s decision, not this run\'s, so '
            + 'recording it would let the next run think it may move it');

        ServiceAppointment untouched = [
            SELECT Status, SchedStartTime FROM ServiceAppointment
            WHERE Id = :fixture.appointmentId LIMIT 1];
        System.assertEquals('Dispatched', untouched.Status);
        System.assertEquals(byHand, untouched.SchedStartTime,
            'the hand-set time has to survive the run');
        System.assertEquals(1, [SELECT COUNT() FROM AssignedResource
                                WHERE ServiceAppointmentId = :fixture.appointmentId]);
    }

    @IsTest
    static void theSignatureRecordsWhatTheRunItselfDecided() {
        Fixture fixture = seed();
        TimefoldRoutesExtract.Problem problem = TimefoldRoutesExtract.run(3);
        List<TimefoldRoutesWriteback.Stop> stops =
            TimefoldRoutesWriteback.stopsFrom(
                solvedRoute(fixture.engineerName, fixture.appointmentId));

        Test.startTest();
        TimefoldRoutesWriteback.Result result =
            TimefoldRoutesWriteback.apply(problem, stops, new List<String>());
        Test.stopTest();

        String expected = TimefoldRoutesExtract.SIGNATURE_VERSION + '\n'
            + TimefoldRoutesExtract.placementOf(
                fixture.appointmentId, fixture.engineerId,
                Datetime.newInstanceGmt(2026, 9, 7, 9, 15, 0));
        System.assertEquals(expected, result.signatureText(),
            'the next run compares against exactly this');
    }

    @IsTest
    static void aSignatureThisCodeCannotReadIsIgnoredNotCompared() {
        Fixture fixture = seed();
        commitByHand(fixture, MONDAY.addHours(1), 'Scheduled');
        // An older shape: milliseconds, and no version header.
        insert new Timefold_Run__c(
            Model__c = 'Routes', Status__c = 'Done', Poll_Count__c = 1,
            Plan_Signature__c = fixture.appointmentId + '|'
                + fixture.engineerId + '|' + MONDAY.getTime());

        Test.startTest();
        TimefoldRoutesExtract.Problem problem = TimefoldRoutesExtract.run(3);
        Test.stopTest();

        System.assertEquals(0, problem.pinnedVisits().size(),
            'an unreadable signature matches nothing, which would pin every '
            + 'scheduled visit in the org; ignoring it frees them instead');
    }

    // ------------------------------------------------------------ demo users

    /**
     * Users for the demo staff, from whatever licences the org has.
     *
     * Nothing but User DML in this method, deliberately: User is a setup
     * object and Apex refuses DML on a setup and a non-setup object in one
     * transaction, in either order. That is also why the seeder cannot do this
     * itself and scripts/apex/users.apex exists.
     */
    @IsTest
    static void demoUsersAreCreatedFromWhateverLicencesExist() {
        Test.startTest();
        // More than any org has, so the creation path is reached whatever the
        // org already holds. The refusals it collects are part of the point.
        String said = TimefoldSeed.ensureDemoUsers(200);
        Test.stopTest();

        System.assert(String.isNotBlank(said), 'it has to say what it did');
        System.assert(said.contains('Created') || said.contains('No licence'),
            'either it made some or it said why not: ' + said);
    }

    @IsTest
    static void demoUserCreationCanBeSwitchedOff() {
        insert new Timefold_Setting__c(
            Name = 'Seed.CreateDemoUsers', Value__c = 'false');
        TimefoldRules.reset();

        Test.startTest();
        String said = TimefoldSeed.ensureDemoUsers(200);
        Test.stopTest();

        System.assert(said.contains('is off'), said);
        // No User DML at all on this path, which is what makes it safe to call
        // from a transaction that has already touched something else.
    }

    // ----------------------------------------------------------- the seeder

    /**
     * The field service half of the seeder.
     *
     * Seeded on top of the fixture on purpose. TimefoldSeed sizes itself to the
     * org, and inside one transaction the nurses claim every spare User
     * licence first, so an engineer can only be found rather than created. A
     * region that already has one is what a real re-run looks like anyway.
     */
    @IsTest
    static void theSeederBuildsTheRoundAndReAnchorsIt() {
        Fixture fixture = seed();

        Test.startTest();
        TimefoldSeed.Report first = TimefoldSeed.run(7);
        TimefoldSeed.Report second = TimefoldSeed.run(7);
        Test.stopTest();

        System.assertEquals(2, first.regions, first.toString());
        System.assert(first.engineers >= 1, first.toString());
        System.assert(first.visits > 1,
            'the round should have been seeded: ' + first.toString());
        System.assertEquals(first.visits, second.visits,
            'a second run must move the round, not double it');

        // Every job is anchored on a working day at 08:00, and carries
        // coordinates that nothing re-geocoded.
        Datetime anchor = TimefoldSeed.fieldServiceAnchor();
        List<ServiceAppointment> seeded = [
            SELECT Subject, EarliestStartTime, DueDate, Latitude, Longitude,
                   ParentRecordId
            FROM ServiceAppointment
            WHERE ServiceTerritoryId = :fixture.regionId
              AND Subject LIKE '%Ventilator Service%'];
        System.assert(!seeded.isEmpty(), 'no round was seeded');
        for (ServiceAppointment visit : seeded) {
            System.assertEquals(anchor, visit.EarliestStartTime, visit.Subject);
            System.assert(visit.DueDate > visit.EarliestStartTime, visit.Subject);
            System.assertNotEquals(null, visit.Latitude, visit.Subject);
            System.assertNotEquals(null, visit.ParentRecordId,
                'the certificate a job demands hangs off the parent WorkOrder');
        }

        // And the engineer can actually be routed: a home base on the
        // membership, and hours to work.
        List<ServiceTerritoryMember> members = [
            SELECT Latitude, Longitude, OperatingHoursId
            FROM ServiceTerritoryMember
            WHERE ServiceTerritoryId = :fixture.regionId];
        for (ServiceTerritoryMember member : members) {
            System.assertNotEquals(null, member.Latitude,
                'without a home base the engineer is left out of the request');
            System.assertNotEquals(null, member.OperatingHoursId);
        }
    }

    @IsTest
    static void theRoundIsAnchoredOnAWorkingDay() {
        Datetime anchor = TimefoldSeed.fieldServiceAnchor();
        System.assertEquals(8, anchor.hourGmt(), 'the shift starts at 08:00');
        String day = TimefoldRoutesRequest.weekdayOf(anchor);
        System.assert(day != 'Saturday' && day != 'Sunday',
            'the crew has no weekend cover, so a weekend anchor would give a '
            + 'window with no shifts in it at all: ' + day);
        // Both sides GMT. Comparing a GMT date against Date.today(), which is
        // the running user's timezone, is what let this through before: on a
        // Pacific-time org seeded from Europe the round landed on yesterday
        // and the assertion still held.
        System.assert(anchor.dateGmt() >= Datetime.now().dateGmt(),
            'both consoles open on today, so the round has to be there: ' + anchor);
        System.assert(anchor > Datetime.now(),
            'a round that has already started is one nobody can watch: ' + anchor);
    }

    // ---------------------------------------------------------------- helpers

    /**
     * The smallest routing problem the extract can find: a root territory, one
     * region under it, one engineer with a home base and one job.
     *
     * The territory is named for the Routes.RootTerritory default, because a
     * test cannot see the Timefold_Setting__c rows that would override it.
     */
    private static Fixture seed() {
        TimefoldRules.reset();
        OperatingHours hours = new OperatingHours(
            Name = 'Field service 08:00-17:00', TimeZone = 'Europe/London');
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

        ServiceTerritory root = new ServiceTerritory(
            Name = 'St. Elmore Field Service', OperatingHoursId = hours.Id,
            IsActive = true);
        insert root;
        ServiceTerritory region = new ServiceTerritory(
            Name = 'London North', ParentTerritoryId = root.Id,
            OperatingHoursId = hours.Id, IsActive = true);
        insert region;

        ServiceResource engineer = new ServiceResource(
            Name = 'Nadia Rahimi', ResourceType = 'T', IsActive = true,
            RelatedRecordId = UserInfo.getUserId(),
            LastKnownLatitude = 1, LastKnownLongitude = 1);
        insert engineer;
        insert new ServiceTerritoryMember(
            ServiceResourceId = engineer.Id, ServiceTerritoryId = region.Id,
            TerritoryType = 'P', OperatingHoursId = hours.Id,
            EffectiveStartDate = MONDAY.addDays(-30),
            Latitude = 51.58, Longitude = -0.15);

        WorkOrder order = new WorkOrder(ServiceTerritoryId = region.Id);
        insert order;
        ServiceAppointment appointment = new ServiceAppointment(
            ParentRecordId = order.Id, ServiceTerritoryId = region.Id,
            Subject = 'Infusion Pump Service', Status = 'None',
            EarliestStartTime = MONDAY, DueDate = MONDAY.addHours(9),
            Duration = 45, DurationType = 'Minutes',
            Latitude = 51.5, Longitude = -0.05);
        insert appointment;

        Fixture fixture = new Fixture();
        fixture.regionId = region.Id;
        fixture.engineerId = engineer.Id;
        fixture.engineerName = engineer.Name;
        fixture.appointmentId = appointment.Id;
        return fixture;
    }

    /**
     * Give the fixture's engineer the job, at a time a person chose.
     *
     * Two steps when the target is past Scheduled, because Field Service
     * enforces its own lifecycle: "Cannot change status from None to
     * Dispatched". A dispatcher goes through the same two steps in the
     * console, which is rather the point of treating Dispatched as committed.
     */
    private static void commitByHand(Fixture fixture, Datetime startsAt,
                                     String status) {
        update new ServiceAppointment(
            Id = fixture.appointmentId, SchedStartTime = startsAt,
            SchedEndTime = startsAt.addMinutes(45), Status = 'Scheduled');
        insert new AssignedResource(
            ServiceAppointmentId = fixture.appointmentId,
            ServiceResourceId = fixture.engineerId);
        if (status != 'Scheduled') {
            update new ServiceAppointment(
                Id = fixture.appointmentId, Status = status);
        }
    }

    /** A finished routing run that recorded these placements. */
    private static void recordPlan(String placement) {
        insert new Timefold_Run__c(
            Model__c = 'Routes', Status__c = 'Done', Poll_Count__c = 1,
            Plan_Signature__c =
                TimefoldRoutesExtract.SIGNATURE_VERSION + '\n' + placement);
    }

    /** Book leave for the hand-built problem's only engineer. */
    private static void addLeave(TimefoldRoutesExtract.Problem problem,
                                 Integer fromHour, Integer fromMinute,
                                 Integer toHour, Integer toMinute) {
        TimefoldRosterExtract.Absence absence =
            new TimefoldRosterExtract.Absence();
        absence.resourceId = problem.technicians[0].recordId;
        absence.kind = 'Meeting';
        absence.startAt = Datetime.newInstanceGmt(2026, 9, 7, fromHour, fromMinute, 0);
        absence.endAt = Datetime.newInstanceGmt(2026, 9, 7, toHour, toMinute, 0);
        problem.technicians[0].absences.add(absence);
    }

    /** Say a person put this visit on this engineer at this time. */
    private static void pin(TimefoldRoutesExtract.Visit visit,
                            TimefoldRoutesExtract.Technician tech,
                            Datetime startsAt) {
        visit.pinReason = 'Pinned in the dispatcher console.';
        visit.scheduledStart = startsAt;
        visit.assignedResourceIds.clear();
        visit.assignedResourceIds.add(tech.recordId);
    }

    /** A second visit on the hand-built problem, so two pins can be ordered. */
    private static TimefoldRoutesExtract.Visit secondVisit(
            TimefoldRoutesExtract.Problem problem) {
        TimefoldRoutesExtract.Visit visit = new TimefoldRoutesExtract.Visit();
        visit.recordId = '08p000000000001AAA';
        visit.name = 'Ventilator Service';
        visit.latitude = 51.6;
        visit.longitude = -0.1;
        visit.durationMinutes = 30;
        visit.region = 'London North';
        problem.visits.add(visit);
        return visit;
    }

    /** The first shift of the first vehicle in a built request. */
    private static Map<String, Object> firstShift(String body) {
        Map<String, Object> input = (Map<String, Object>)
            ((Map<String, Object>) JSON.deserializeUntyped(body)).get('modelInput');
        Map<String, Object> vehicle =
            (Map<String, Object>) ((List<Object>) input.get('vehicles'))[0];
        return (Map<String, Object>) ((List<Object>) vehicle.get('shifts'))[0];
    }

    /** Any active User other than the one running the test. */
    private static Id spareUser() {
        List<User> spare = [
            SELECT Id FROM User
            WHERE IsActive = TRUE AND Id != :UserInfo.getUserId() LIMIT 1];
        System.assert(!spare.isEmpty(),
            'this test needs a second active User, because ServiceResource '
            + 'RelatedRecordId is unique');
        return spare[0].Id;
    }

    /**
     * A routing problem built in memory.
     *
     * Skill is a setup object Apex cannot insert, so the only way to cover
     * skill declaration is to build the problem rather than query it.
     */
    private static TimefoldRoutesExtract.Problem handBuilt() {
        TimefoldRules.reset();
        TimefoldRoutesExtract.Problem problem =
            new TimefoldRoutesExtract.Problem();
        problem.windowStart = Datetime.newInstanceGmt(2026, 9, 7, 0, 0, 0);
        problem.windowEnd = problem.windowStart.addDays(3);

        TimefoldRosterExtract.DailyWindow window =
            new TimefoldRosterExtract.DailyWindow();
        window.startSeconds = 8 * 3600;
        window.endSeconds = 17 * 3600;
        Id hoursId = '0OH000000000000AAA';
        for (String day : new List<String>{
                'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday' }) {
            TimefoldRosterExtract.DailyWindow copy =
                new TimefoldRosterExtract.DailyWindow();
            copy.dayOfWeek = day;
            copy.startSeconds = window.startSeconds;
            copy.endSeconds = window.endSeconds;
            if (!problem.operatingHours.containsKey(hoursId)) {
                problem.operatingHours.put(hoursId,
                    new List<TimefoldRosterExtract.DailyWindow>());
            }
            problem.operatingHours.get(hoursId).add(copy);
        }

        TimefoldRoutesExtract.Technician tech =
            new TimefoldRoutesExtract.Technician();
        tech.recordId = '0Hn000000000000AAA';
        tech.name = 'Nadia Rahimi';
        tech.region = 'London North';
        tech.homeLatitude = 51.58;
        tech.homeLongitude = -0.15;
        tech.operatingHoursId = hoursId;
        tech.skills.put('Infusion Pumps', 5);
        problem.technicians.add(tech);

        TimefoldRoutesExtract.Visit visit = new TimefoldRoutesExtract.Visit();
        visit.recordId = '08p000000000000AAA';
        visit.name = 'Infusion Pump Service';
        visit.latitude = 51.5;
        visit.longitude = -0.05;
        visit.durationMinutes = 45;
        visit.earliest = problem.windowStart.addHours(8);
        visit.due = problem.windowStart.addHours(17);
        visit.region = 'London North';
        visit.requiredSkills.put('Infusion Pumps', 3);
        problem.visits.add(visit);
        return problem;
    }

    /** One solved shift: a visit, a break that is not one, and a leftover. */
    private static Map<String, Object> solvedRoute(String engineer,
                                                   String visitId) {
        return new Map<String, Object>{
            'modelOutput' => new Map<String, Object>{
                'vehicles' => new List<Object>{
                    new Map<String, Object>{
                        'id' => engineer,
                        'shifts' => new List<Object>{
                            new Map<String, Object>{
                                'id' => engineer + '::2026-09-07T08:00',
                                'itinerary' => new List<Object>{
                                    new Map<String, Object>{
                                        'kind' => 'VISIT',
                                        'id' => visitId,
                                        'arrivalTime' => '2026-09-07T09:10:00Z',
                                        'startServiceTime' => '2026-09-07T09:15:00Z',
                                        'departureTime' => '2026-09-07T10:00:00Z',
                                        'travelTimeFromPreviousStandstill' => 'PT12M',
                                        'travelDistanceMetersFromPreviousStandstill'
                                            => 4200 },
                                    new Map<String, Object>{
                                        'kind' => 'BREAK',
                                        'id' => 'lunch' } } } } } },
                'unassignedVisits' => new List<Object>{ 'visit-2' } } };
    }
}
