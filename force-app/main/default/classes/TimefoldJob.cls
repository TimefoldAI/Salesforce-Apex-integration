/**
 * Runs a solve across transactions, because Apex cannot wait for one.
 *
 * A solve takes a minute or more. An Apex callout is capped at 120 seconds, and
 * there is no sleep, no thread to block and nothing that survives the end of a
 * transaction. So a run is spread across several transactions, and the
 * Timefold_Run__c record is the only thing that remembers what is going on:
 *
 *     start()   creates the run record, enqueues phase SUBMIT
 *     SUBMIT    extract -> build -> POST -> store the job id -> enqueue POLL
 *     POLL      GET the metadata; still solving? enqueue POLL again, later
 *               finished? GET the solution, write it back, close the run
 *
 * Each POLL is a fresh queueable with a delay, which is the only way Apex has
 * of saying "come back in a minute".
 *
 * A Developer Edition org allows a chain of only five queueable jobs, so the
 * number of polls is capped and a run that outlives them fails with something
 * a reader can act on rather than stopping silently.
 */
public with sharing class TimefoldJob implements Queueable, Database.AllowsCallouts {

    public enum Phase { SUBMIT, POLL }

    /** Minutes to wait before looking again. The platform allows 0 to 10. */
    @TestVisible
    private static Integer pollDelayMinutes = 1;

    /**
     * How many times to come back before giving up.
     *
     * Five is the queueable chain limit in a Developer Edition org, and the
     * SUBMIT phase has already used one link.
     */
    @TestVisible
    private static Integer maxPolls = 3;

    private final Id runId;
    private final Phase runPhase;

    public TimefoldJob(Id runId, Phase runPhase) {
        this.runId = runId;
        this.runPhase = runPhase;
    }

    /**
     * Begin a run. Returns the Timefold_Run__c id so a caller can point at it.
     *
     * Refuses a second run of the same model while one is in flight. A
     * dispatcher who presses the button twice, or an action fired with thirty
     * records selected, would otherwise submit thirty identical datasets that
     * burn solver time and race each other writing the results.
     */
    public static Id start(String model) {
        List<Timefold_Run__c> running = [
            SELECT Id FROM Timefold_Run__c
            WHERE Model__c = :model
              AND Status__c IN ('Building', 'Submitted', 'Solving', 'Writing')
            LIMIT 1];
        if (!running.isEmpty()) {
            return running[0].Id;
        }

        Timefold_Run__c run = new Timefold_Run__c(
            Model__c = model, Status__c = 'Building', Poll_Count__c = 0);
        insert run;
        System.enqueueJob(new TimefoldJob(run.Id, TimefoldJob.Phase.SUBMIT));
        return run.Id;
    }

    public void execute(QueueableContext context) {
        Timefold_Run__c run = [
            SELECT Id, Model__c, Status__c, Timefold_Job_Id__c, Poll_Count__c,
                   Window_Start__c, Window_End__c, Records_Planned__c, Error__c
            FROM Timefold_Run__c WHERE Id = :runId LIMIT 1];
        try {
            if (runPhase == Phase.SUBMIT) {
                submit(run);
            } else {
                poll(run);
            }
        } catch (Exception e) {
            fail(run, e.getTypeName() + ': ' + e.getMessage()
                 + '\n' + e.getStackTraceString());
        }
    }

    // ------------------------------------------------------------------ submit

    private void submit(Timefold_Run__c run) {
        String body;
        if (run.Model__c == 'Routes') {
            TimefoldRoutesExtract.Problem problem =
                TimefoldRoutesExtract.run(TimefoldRules.count('Routes.PlanningDays'));
            TimefoldRoutesRequest.Notes notes = new TimefoldRoutesRequest.Notes();
            body = TimefoldRoutesRequest.build(problem, notes);
            run.Window_Start__c = problem.windowStart;
            run.Window_End__c = problem.windowEnd;
            run.Records_Planned__c = notes.visits;
            // What was left out, said up front. A plan that quietly covers 8
            // of 10 jobs is worse than one that says which two it dropped.
            run.Error__c = leftOut(notes);
            if (notes.vehicles == 0) {
                fail(run, 'No engineer can be routed. '
                    + 'Every ServiceResource under "'
                    + TimefoldRules.text('Routes.RootTerritory')
                    + '" is either inactive, not a member of one of its '
                    + 'territories, or has no home base: the write-back needs '
                    + 'Latitude and Longitude on the ServiceTerritoryMember. '
                    + (String.isBlank(run.Error__c) ? '' : run.Error__c));
                return;
            }
            if (notes.visits == 0) {
                fail(run, 'No visit can be routed. '
                    + (notes.visitsWithoutCoordinates > 0
                       ? notes.visitsWithoutCoordinates + ' appointment(s) in the '
                         + 'window have no coordinates yet: Salesforce geocodes '
                         + 'an address asynchronously, so wait a minute and try '
                         + 'again.'
                       : 'There are no ServiceAppointment records in the '
                         + 'planning window.'));
                return;
            }
        } else {
            TimefoldRosterExtract.Problem problem =
                TimefoldRosterExtract.run(TimefoldRules.count('Roster.PlanningDays'));
            body = TimefoldRosterRequest.build(problem);
            run.Window_Start__c = problem.windowStart;
            run.Window_End__c = problem.windowEnd;
            run.Records_Planned__c = problem.shifts.size();
        }

        String jobId = TimefoldClient.submit(modelFor(run.Model__c), body);
        run.Timefold_Job_Id__c = jobId;
        run.Status__c = 'Submitted';
        update run;

        enqueuePoll(run.Id);
    }

    /** Which Timefold model a run belongs to. */
    private static TimefoldClient.Model modelFor(String model) {
        return model == 'Routes'
            ? TimefoldClient.fieldServiceRouting()
            : TimefoldClient.employeeScheduling();
    }

    /** What the request carried, and what it could not, as a sentence. */
    private static String leftOut(TimefoldRoutesRequest.Notes notes) {
        List<String> said = new List<String>();
        if (!notes.engineersWithoutHome.isEmpty()) {
            said.add('Left out for having no home base on their '
                + 'ServiceTerritoryMember: '
                + String.join(notes.engineersWithoutHome, ', ') + '.');
        }
        if (notes.visitsWithoutCoordinates > 0) {
            said.add(notes.visitsWithoutCoordinates + ' appointment(s) left out '
                + 'for having no coordinates. Salesforce geocodes an address '
                + 'asynchronously, so a freshly seeded one can arrive here with '
                + 'nothing to route to.');
        }
        if (notes.visitsCancelled > 0) {
            said.add(notes.visitsCancelled + ' cancelled appointment(s) left out.');
        }
        if (notes.pinned > 0) {
            said.add(notes.pinned + ' visit(s) pinned: already dispatched, or '
                + 'scheduled by hand, so the solver may not move them.');
        }
        if (!notes.pinsDropped.isEmpty()) {
            // Never silent. Unpinning a job a dispatcher committed to,
            // without saying so, is the worst of the three options.
            said.add('Could not pin, because no shift of that engineer covers '
                + 'the time they are scheduled at: '
                + String.join(notes.pinsDropped, ', ')
                + '. The solver is free to move these.');
        }
        if (notes.breaks > 0) {
            said.add(notes.breaks + ' break(s) sent from ResourceAbsence.');
        }
        if (notes.shiftsDroppedForLeave > 0) {
            said.add(notes.shiftsDroppedForLeave + ' shift(s) dropped: on leave '
                + 'for the whole day.');
        }
        return said.isEmpty() ? null : String.join(said, ' ');
    }

    /**
     * Queue the next look.
     *
     * Guarded because a test cannot chain a queueable at all - the stack depth
     * inside a test is one, and enqueueing from a running job raises
     * "Maximum stack depth has been reached". The alternative is not testing
     * the submit phase, which is where the request is built.
     */
    private static void enqueuePoll(Id runId) {
        if (Test.isRunningTest()) {
            return;
        }
        System.enqueueJob(new TimefoldJob(runId, TimefoldJob.Phase.POLL),
                          pollDelayMinutes);
    }

    // -------------------------------------------------------------------- poll

    private void poll(Timefold_Run__c run) {
        TimefoldClient.Model model = modelFor(run.Model__c);
        Map<String, Object> meta = TimefoldClient.status(model, run.Timefold_Job_Id__c);
        String state = String.valueOf(meta.get('solverStatus'));

        run.Poll_Count__c = (run.Poll_Count__c == null ? 0 : run.Poll_Count__c) + 1;
        run.Solver_Status__c = state;

        if (TimefoldClient.FAILED.contains(state)) {
            // Read the validation result before giving up: DATASET_INVALID
            // says almost nothing on its own, and the validation result says
            // exactly which id or tag was wrong. Still a callout, so it has to
            // happen before the update below.
            recordValidation(run, model);
            run.Status__c = 'Failed';
            run.Error__c = 'Timefold ended the run as ' + state + '. '
                + String.valueOf(meta.get('failureMessage'));
            run.Finished__c = Datetime.now();
            update run;
            return;
        }

        if (!TimefoldClient.DONE.contains(state)) {
            if (run.Poll_Count__c >= maxPolls) {
                fail(run, 'Still ' + state + ' after ' + run.Poll_Count__c
                    + ' checks. A Developer Edition org allows a chain of only '
                    + 'five queueable jobs, so this run cannot wait any longer. '
                    + 'Lower the ' + run.Model__c + '.SolverSeconds Timefold '
                    + 'Setting, or read the answer with TimefoldJob.collect(\''
                    + run.Id + '\').');
                return;
            }
            run.Status__c = 'Solving';
            update run;
            enqueuePoll(run.Id);
            return;
        }

        finish(run, model, meta);
    }

    /**
     * Pick up a run that outlived its polls, from wherever it got to.
     *
     *     TimefoldJob.collect('a0Xxx...');
     */
    public static void collect(Id runId) {
        Timefold_Run__c run = [
            SELECT Id, Model__c, Status__c, Timefold_Job_Id__c, Poll_Count__c,
                   Window_Start__c, Window_End__c, Records_Planned__c, Error__c
            FROM Timefold_Run__c WHERE Id = :runId LIMIT 1];
        TimefoldClient.Model model = modelFor(run.Model__c);
        new TimefoldJob(runId, TimefoldJob.Phase.POLL).finish(
            run, model, TimefoldClient.status(model, run.Timefold_Job_Id__c));
    }

    /**
     * Read the solution and write it back.
     *
     * Every callout happens before any DML, and that ordering is not a matter
     * of taste: Apex refuses a callout once the transaction holds uncommitted
     * DML - "You have uncommitted work pending. Please commit or rollback
     * before calling out."
     *
     * So the run record is only mutated in memory here, and saved at the end.
     */
    private void finish(Timefold_Run__c run, TimefoldClient.Model model,
                        Map<String, Object> meta) {
        Map<String, Object> solution = TimefoldClient.fetch(model, run.Timefold_Job_Id__c);
        recordValidation(run, model);       // the last callout
        run.Score__c = readScore(solution, meta);

        if (run.Model__c == 'Routes') {
            finishRoutes(run, solution);
        } else {
            finishRoster(run, solution);
        }

        run.Status__c = 'Done';
        run.Finished__c = Datetime.now();
        update run;
    }

    private void finishRoster(Timefold_Run__c run, Map<String, Object> solution) {
        // The window is read again rather than trusted from the record: this
        // transaction needs the shift and nurse rows to map names back to ids,
        // and re-reading is cheaper than carrying the whole problem across.
        TimefoldRosterExtract.Problem problem =
            TimefoldRosterExtract.run(TimefoldRules.count('Roster.PlanningDays'));

        Map<String, String> assignments =
            TimefoldRosterWriteback.assignmentsFrom(solution);
        Integer unfilled = 0;
        for (String value : assignments.values()) {
            if (String.isBlank(value)) {
                unfilled++;
            }
        }
        TimefoldRosterWriteback.Result written =
            TimefoldRosterWriteback.apply(problem, assignments);

        run.Records_Written__c = written.written();
        run.Unassigned__c = unfilled;
        if (!written.errors.isEmpty() || !written.unknownEmployees.isEmpty()) {
            run.Error__c = (written.errors.isEmpty() ? '' :
                    'Salesforce refused some updates:\n'
                    + String.join(written.errors, '\n') + '\n')
                + (written.unknownEmployees.isEmpty() ? '' :
                    'Timefold named employees this org does not have: '
                    + String.join(new List<String>(written.unknownEmployees), ', '));
        }
    }

    private void finishRoutes(Timefold_Run__c run, Map<String, Object> solution) {
        TimefoldRoutesExtract.Problem problem =
            TimefoldRoutesExtract.run(TimefoldRules.count('Routes.PlanningDays'));

        List<TimefoldRoutesWriteback.Stop> stops =
            TimefoldRoutesWriteback.stopsFrom(solution);
        List<String> unassigned = TimefoldRoutesWriteback.unassignedFrom(solution);
        TimefoldRoutesWriteback.Result written =
            TimefoldRoutesWriteback.apply(problem, stops, unassigned);

        run.Records_Written__c = written.written();
        run.Unassigned__c = unassigned.size();
        run.Plan_Signature__c = written.signatureText();
        readTravel(run, solution);

        List<String> said = new List<String>();
        // What submit() noticed - an engineer with no home base, an
        // appointment with no coordinates - still matters once the plan is in.
        if (String.isNotBlank(run.Error__c)) {
            said.add(run.Error__c);
        }
        if (written.linksRemoved > 0 || written.linksCreated > 0) {
            said.add('AssignedResource: ' + written.linksCreated + ' created, '
                + written.linksRemoved + ' stale link(s) removed.');
        }
        if (written.leftPinned > 0) {
            said.add(written.leftPinned + ' visit(s) left exactly where they '
                + 'were, because a person had already committed to them.');
        }
        if (!written.unknownEngineers.isEmpty()) {
            said.add('Timefold named engineers this org does not have: '
                + String.join(new List<String>(written.unknownEngineers), ', '));
        }
        if (!written.errors.isEmpty()) {
            said.add('Salesforce refused some writes:\n'
                + String.join(written.errors, '\n'));
        }
        run.Error__c = said.isEmpty() ? null : String.join(said, '\n');
    }

    /**
     * Total driving of the whole plan, off the run's KPIs.
     *
     * Worth recording because it is the one number that shows the routing is
     * real: these are OSRM road distances from the platform's maps service, not
     * straight lines. Salesforce's own header figure in the dispatcher console
     * is its own calculation and will not match.
     */
    private static void readTravel(Timefold_Run__c run,
                                   Map<String, Object> solution) {
        Object kpis = solution == null ? null : solution.get('kpis');
        if (!(kpis instanceof Map<String, Object>)) {
            return;
        }
        Map<String, Object> metrics = (Map<String, Object>) kpis;
        Decimal hours = hoursFrom(metrics.get('totalTravelTime'));
        if (hours != null) {
            run.Travel_Time_Hours__c = hours.setScale(2);
        }
        Object meters = metrics.get('totalTravelDistanceMeters');
        if (meters != null) {
            run.Travel_Distance_Km__c =
                (Decimal.valueOf(String.valueOf(meters)) / 1000).setScale(1);
        }
    }

    /**
     * An ISO-8601 duration as hours.
     *
     * Timefold reports every duration this way - PT5H6M30S, sometimes with a
     * day part - and Apex has nothing that parses one.
     */
    @TestVisible
    private static Decimal hoursFrom(Object value) {
        if (value == null) {
            return null;
        }
        String text = String.valueOf(value).trim().toUpperCase();
        if (!text.startsWith('P')) {
            return null;
        }
        Decimal total = 0;
        String digits = '';
        Boolean inTime = false;
        for (Integer i = 1; i < text.length(); i++) {
            String ch = text.substring(i, i + 1);
            if (ch == 'T') {
                inTime = true;
            } else if (ch.isNumeric() || ch == '.') {
                digits += ch;
            } else {
                if (String.isBlank(digits)) {
                    continue;
                }
                Decimal amount = Decimal.valueOf(digits);
                if (ch == 'D') {
                    total += amount * 24;
                } else if (ch == 'H') {
                    total += amount;
                } else if (ch == 'M' && inTime) {
                    total += amount / 60;
                } else if (ch == 'S') {
                    total += amount / 3600;
                }
                digits = '';
            }
        }
        return total;
    }

    /**
     * Store the input validation result, warnings included.
     *
     * Timefold checks the input on every run and can warn while still
     * succeeding. TRAVEL_WEIGHT_CONFLICT is the example that matters: nothing
     * fails, no score looks wrong, and the plan is optimising something you did
     * not ask for. Fetched after every run, not only after a failure.
     */
    private void recordValidation(Timefold_Run__c run, TimefoldClient.Model model) {
        try {
            Map<String, Object> validation =
                TimefoldClient.validation(model, run.Timefold_Job_Id__c);
            run.Validation_Status__c = String.valueOf(validation.get('status'));
            Object issues = validation.get('issues');
            if (issues instanceof List<Object> && !((List<Object>) issues).isEmpty()) {
                String text = JSON.serialize(issues);
                run.Validation_Detail__c =
                    text.length() > 32000 ? text.substring(0, 32000) : text;
            }
        } catch (Exception e) {
            run.Validation_Status__c = 'unavailable';
            run.Validation_Detail__c = e.getMessage();
        }
    }

    private static String readScore(Map<String, Object> solution,
                                    Map<String, Object> meta) {
        for (Map<String, Object> source : new List<Map<String, Object>>{ solution, meta }) {
            if (source == null) {
                continue;
            }
            Object score = source.get('score');
            if (score != null) {
                return String.valueOf(score);
            }
            Object run = source.get('run');
            if (run instanceof Map<String, Object>) {
                Object nested = ((Map<String, Object>) run).get('score');
                if (nested != null) {
                    return String.valueOf(nested);
                }
            }
        }
        return null;
    }

    private void fail(Timefold_Run__c run, String message) {
        // A separate DML from whatever failed, so the reason is recorded even
        // when the transaction that produced it is rolled back.
        Timefold_Run__c failed = new Timefold_Run__c(
            Id = run.Id, Status__c = 'Failed', Finished__c = Datetime.now(),
            Error__c = message.length() > 32000 ? message.substring(0, 32000) : message);
        update failed;
    }
}
