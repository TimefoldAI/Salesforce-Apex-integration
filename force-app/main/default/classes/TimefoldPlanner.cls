/**
 * What the button calls.
 *
 * Deliberately thin. It starts a run and turns the answer into a sentence; the
 * work is in TimefoldJob and the rules are in Timefold_Setting__c records, so
 * neither needs a deployment to change.
 *
 * It returns immediately, because it has to: the run is asynchronous and a
 * solve takes longer than the screen can wait. So a success here means "the
 * run started", not "the roster is done". The Timefold Run record it names is
 * where the answer appears.
 */
public with sharing class TimefoldPlanner {

    public class Request {
        @InvocableVariable(
            label='Model'
            description='Roster for the nurse rota, Routes for the field service round'
            required=true)
        public String model;
    }

    public class Result {
        @InvocableVariable(label='Started') public Boolean started;
        @InvocableVariable(label='Message') public String message;
        @InvocableVariable(label='Run Id') public String runId;
    }

    @InvocableMethod(
        label='Optimise with Timefold'
        description='Starts a Timefold optimisation run over this org\'s data.'
        category='Timefold')
    public static List<Result> run(List<Request> requests) {
        List<Result> results = new List<Result>();
        // One run per invocation, whatever the caller sent. An action fired
        // with thirty records selected hands this thirty requests that all
        // mean the same thing, and TimefoldJob.start refuses the duplicates
        // anyway - but there is no reason to ask it thirty times.
        Set<String> models = new Set<String>();
        for (Request request : requests) {
            models.add(String.isBlank(request.model)
                       ? 'Roster' : request.model.trim());
        }
        for (String model : models) {
            results.add(startOne(model));
        }
        // A Flow expects one output per input when it called with one input.
        while (results.size() < requests.size()) {
            results.add(results[0]);
        }
        return results;
    }

    private static Result startOne(String model) {
        Result result = new Result();
        try {
            Id runId = TimefoldJob.start(model);
            Timefold_Run__c run = [
                SELECT Name, Status__c FROM Timefold_Run__c
                WHERE Id = :runId LIMIT 1];
            result.runId = runId;
            result.started = true;
            result.message = run.Status__c == 'Building'
                ? 'Optimising ' + scope(model) + '. Run ' + run.Name
                  + ' shows the progress; the records update when the solver finishes.'
                : 'A run for ' + scope(model) + ' is already in progress ('
                  + run.Name + ').';
        } catch (Exception e) {
            result.started = false;
            result.message = 'Could not start the run: ' + e.getMessage();
        }
        return result;
    }

    /**
     * Name what actually gets replanned.
     *
     * A message that says only "optimising", read next to whatever record
     * somebody had open, invites them to think it did something smaller.
     */
    private static String scope(String model) {
        return model == 'Routes'
            ? 'the whole field service round'
            : 'the whole nurse rota';
    }
}
