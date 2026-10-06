/**
 * Client for the Timefold Model API, called straight out of Apex.
 *
 * Both models follow the same shape:
 *
 *     POST callout:Timefold/api/models/{model}/v1/{collection}      -> a job id
 *     GET  callout:Timefold/api/models/{model}/v1/{collection}/{id}
 *
 * Authentication is one header, X-API-KEY, and this class never sees it: the
 * Timefold Named Credential adds it from the Timefold_API External Credential,
 * where an administrator put the key once and nothing can read it back.
 *
 * Nothing here waits for a solver. A Salesforce callout is capped at 120
 * seconds and a solve takes longer, so the caller submits, and then a queueable
 * comes back later to look. See TimefoldRun.
 */
public with sharing class TimefoldClient {

    /** Endpoint prefix. The Named Credential supplies the host and the key. */
    @TestVisible
    private static final String CALLOUT = 'callout:Timefold';

    /** Longest a single callout may take. The platform caps this at 120s. */
    private static final Integer TIMEOUT_MS = 120000;

    /** Solver states that mean "finished, there is a solution to read". */
    public static final Set<String> DONE = new Set<String>{
        'SOLVING_COMPLETED', 'SOLVING_INCOMPLETE'
    };

    /** Solver states that mean "stopped, and not with a solution". */
    public static final Set<String> FAILED = new Set<String>{
        'SOLVING_FAILED', 'DATASET_INVALID'
    };

    public class TimefoldException extends Exception {}

    /** One model and the collection it keeps its jobs in. */
    public class Model {
        public String name;
        public String collection;
        public Model(String name, String collection) {
            this.name = name;
            this.collection = collection;
        }
        public String path(String suffix) {
            return '/api/models/' + name + '/v1/' + collection
                 + (String.isBlank(suffix) ? '' : suffix);
        }
    }

    public static Model employeeScheduling() {
        return new Model('employee-scheduling', 'schedules');
    }

    public static Model fieldServiceRouting() {
        return new Model('field-service-routing', 'route-plans');
    }

    // ------------------------------------------------------------------ calls

    /** Submit a dataset. Returns the job id Timefold assigned it. */
    public static String submit(Model model, String requestBody) {
        Object result = call('POST', model.path(''), requestBody,
                             'submit ' + model.name);
        // Timefold answers with the id as a bare JSON string, so the untyped
        // parse gives a String rather than a Map.
        if (result instanceof String) {
            return (String) result;
        }
        if (result instanceof Map<String, Object>) {
            Object id = ((Map<String, Object>) result).get('id');
            if (id != null) {
                return String.valueOf(id);
            }
        }
        throw new TimefoldException('Timefold accepted the dataset but returned '
            + 'no job id: ' + JSON.serialize(result));
    }

    /**
     * The run's metadata, which is where the solver status lives.
     *
     * Deliberately separate from fetch(): the metadata is small and safe to
     * poll, while the full solution carries every shift or visit and would
     * blow the heap if it were read on every poll.
     */
    public static Map<String, Object> status(Model model, String jobId) {
        return asMap(call('GET', model.path('/' + jobId + '/metadata'), null,
                          'status ' + jobId));
    }

    /** The whole solved dataset. Only worth reading once the run is done. */
    public static Map<String, Object> fetch(Model model, String jobId) {
        return asMap(call('GET', model.path('/' + jobId), null, 'fetch ' + jobId));
    }

    /**
     * The input validation result.
     *
     * Worth reading after every run, not only after a failure: it carries
     * warnings even when the solve succeeded, and a warning such as
     * TRAVEL_WEIGHT_CONFLICT means the answer is quietly not the one you meant.
     */
    public static Map<String, Object> validation(Model model, String jobId) {
        return asMap(call('GET', model.path('/' + jobId + '/validation-result'),
                          null, 'validation ' + jobId));
    }

    /** Give the dataset back. Timefold keeps runs otherwise. */
    public static void discard(Model model, String jobId) {
        call('DELETE', model.path('/' + jobId), null, 'delete ' + jobId);
    }

    /** Cheap call that proves the key works, used by TimefoldSetup.check(). */
    public static Map<String, Object> aboutMe() {
        return asMap(call('GET', '/api/aboutme', null, 'aboutme'));
    }

    // ---------------------------------------------------------------- plumbing

    private static Object call(String method, String path, String body,
                               String context) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint(CALLOUT + path);
        request.setMethod(method);
        request.setTimeout(TIMEOUT_MS);
        request.setHeader('Accept', 'application/json');
        if (body != null) {
            request.setHeader('Content-Type', 'application/json');
            request.setBody(body);
        }

        HttpResponse response;
        try {
            response = new Http().send(request);
        } catch (System.CalloutException e) {
            // The ApiKey parameter comes into existence when a key is stored,
            // not when the External Credential is deployed, so an org that
            // has never had a key fails here with "Field Timefold_API.ApiKey
            // does not exist" - which reads like a typo in the Named
            // Credential and is really an empty box.
            String advice = e.getMessage().contains('Timefold_API.ApiKey')
                ? '. No API key is stored yet: the ApiKey parameter appears '
                  + 'once one is. Set it with TIMEFOLD_API_KEY=... '
                  + './scripts/setup.sh, or by hand at Setup > Named '
                  + 'Credentials > External Credentials > Timefold API > '
                  + 'Principals > TimefoldApiKey. A key is free at '
                  + 'https://app.timefold.ai under Settings > API keys.'
                : '. Check the Timefold Named Credential exists and that this '
                  + 'user has access to the Timefold_API external credential '
                  + 'principal - the Timefold_Integration permission set grants it.';
            throw new TimefoldException(
                'Could not reach Timefold (' + context + '): ' + e.getMessage()
                + advice, e);
        }

        Integer status = response.getStatusCode();
        if (status == 401 || status == 403) {
            throw new TimefoldException(
                'Timefold rejected the API key (HTTP ' + status + '). Set it '
                + 'with TIMEFOLD_API_KEY=... ./scripts/setup.sh, or by hand at '
                + 'Setup > Named Credentials > External Credentials > Timefold '
                + 'API > Principals > TimefoldApiKey, as the ApiKey parameter. '
                + 'A key is free at https://app.timefold.ai under Settings > '
                + 'API keys.');
        }
        if (status >= 400) {
            throw new TimefoldException('Timefold returned ' + status + ' for '
                + context + ': ' + truncate(response.getBody()));
        }
        if (status == 204 || String.isBlank(response.getBody())) {
            return null;
        }
        try {
            return JSON.deserializeUntyped(response.getBody());
        } catch (JSONException e) {
            // A body that is not JSON is not automatically a problem: the
            // submit endpoint answers with a bare id.
            return response.getBody().trim().removeStart('"').removeEnd('"');
        }
    }

    private static Map<String, Object> asMap(Object parsed) {
        return parsed instanceof Map<String, Object>
            ? (Map<String, Object>) parsed
            : new Map<String, Object>();
    }

    /** Keep an error message inside what a field or a debug log will hold. */
    private static String truncate(String text) {
        if (String.isBlank(text)) {
            return '(empty)';
        }
        return text.length() > 900 ? text.substring(0, 900) + ' ...' : text;
    }
}
