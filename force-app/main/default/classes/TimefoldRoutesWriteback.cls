/**
 * Step three of the round: where does the answer go?
 *
 * Onto the same standard fields Salesforce's own scheduling optimiser writes,
 * so the plan appears in the ordinary Field Service views with nothing custom:
 *
 *     ServiceAppointment.SchedStartTime / SchedEndTime / Status
 *     AssignedResource                    one per engineer on an appointment
 *
 * Two things about the dispatcher console are worth knowing here, because both
 * make a correct write-back look like a failure:
 *
 *   - The console opens on the date it last showed, not on the plan's date.
 *   - A capacity-based ServiceResource gets no appointment bars at all, so the
 *     row looks empty however good the plan is. See the README.
 */
public with sharing class TimefoldRoutesWriteback {

    /** One visit, as Timefold placed it. */
    public class Stop {
        /**
         * Deliberately a String, not an Id.
         *
         * Timefold echoes back the id the request gave it, which is a
         * ServiceAppointment id - until something in the dataset is not one,
         * and then an Id field throws "Invalid id: ..." and takes the whole
         * write-back down instead of skipping one visit. apply() resolves it
         * against the visits it actually read.
         */
        public String visitId;
        public String engineer;               // the vehicle id, a resource Name
        public String shiftId;
        public Datetime arrival;
        public Datetime startService;
        public Datetime departure;
        public String travelFromPrevious;     // ISO-8601 duration, e.g. PT12M
        public Integer travelMetersFromPrevious;
    }

    public class Result {
        public Integer scheduled = 0;
        public Integer unscheduled = 0;
        public Integer linksCreated = 0;
        public Integer linksRemoved = 0;
        public Integer unchanged = 0;
        public Integer leftPinned = 0;
        public Set<String> unknownEngineers = new Set<String>();
        public List<String> errors = new List<String>();

        /**
         * What this run decided, one placement per line.
         *
         * Stored on Timefold_Run__c.Plan_Signature__c, and read by the next
         * run to tell a manual assignment from an automatic one. Pinned
         * visits are deliberately absent: they were a person's decision, not
         * this run's, and recording them would make the next run think it had
         * placed them and free to move them again.
         */
        public List<String> signature = new List<String>();

        public Integer written() {
            return scheduled + unscheduled;
        }

        public String signatureText() {
            if (signature.isEmpty()) {
                return null;
            }
            // The header is a version. A signature in an unknown format
            // matches nothing, which would pin every scheduled visit in the
            // org, so a reader that does not know the header ignores the whole
            // signature instead.
            return TimefoldRoutesExtract.SIGNATURE_VERSION + '\n'
                 + String.join(signature, '\n');
        }
    }

    /**
     * Flatten the solved plan into one Stop per visit.
     *
     * The route arrives nested three deep - vehicle, shift, itinerary - and
     * the itinerary also carries BREAK items, which are not appointments.
     */
    public static List<Stop> stopsFrom(Map<String, Object> response) {
        List<Stop> stops = new List<Stop>();
        Map<String, Object> output = mapAt(response, 'modelOutput');
        for (Object vehicleItem : listAt(output, 'vehicles')) {
            Map<String, Object> vehicle = (Map<String, Object>) vehicleItem;
            String engineer = text(vehicle.get('id'));
            for (Object shiftItem : listAt(vehicle, 'shifts')) {
                Map<String, Object> shift = (Map<String, Object>) shiftItem;
                for (Object stopItem : listAt(shift, 'itinerary')) {
                    Map<String, Object> entry = (Map<String, Object>) stopItem;
                    if (text(entry.get('kind')) != 'VISIT') {
                        continue;
                    }
                    Stop stop = new Stop();
                    stop.visitId = text(entry.get('id'));
                    stop.engineer = engineer;
                    stop.shiftId = text(shift.get('id'));
                    stop.arrival = parse(text(entry.get('arrivalTime')));
                    stop.startService = parse(text(entry.get('startServiceTime')));
                    stop.departure = parse(text(entry.get('departureTime')));
                    stop.travelFromPrevious =
                        text(entry.get('travelTimeFromPreviousStandstill'));
                    Object meters =
                        entry.get('travelDistanceMetersFromPreviousStandstill');
                    stop.travelMetersFromPrevious = meters == null
                        ? null : Decimal.valueOf(String.valueOf(meters)).intValue();
                    stops.add(stop);
                }
            }
        }
        return stops;
    }

    /** The visits Timefold could not place. */
    public static List<String> unassignedFrom(Map<String, Object> response) {
        List<String> out = new List<String>();
        for (Object item : listAt(mapAt(response, 'modelOutput'), 'unassignedVisits')) {
            out.add(String.valueOf(item));
        }
        return out;
    }

    public static Result apply(TimefoldRoutesExtract.Problem problem,
                               List<Stop> stops, List<String> unassigned) {
        String scheduledStatus = TimefoldRules.text('Routes.ScheduledStatus');
        String unscheduledStatus = TimefoldRules.text('Routes.UnscheduledStatus');

        // Name -> resource id. A duplicate name is reported rather than
        // resolved: picking either one would attach the work to the wrong
        // person and look like a solver mistake.
        Map<String, Id> idOfName = new Map<String, Id>();
        Set<String> duplicated = new Set<String>();
        for (TimefoldRoutesExtract.Technician tech : problem.technicians) {
            if (idOfName.containsKey(tech.name)) {
                duplicated.add(tech.name);
            }
            idOfName.put(tech.name, tech.recordId);
        }

        // Keyed by String for the reason Stop.visitId is one: an id from the
        // response that is not a Salesforce id has to miss the map, not throw.
        Map<String, TimefoldRoutesExtract.Visit> known =
            new Map<String, TimefoldRoutesExtract.Visit>();
        for (TimefoldRoutesExtract.Visit visit : problem.visits) {
            known.put(String.valueOf(visit.recordId), visit);
        }

        Result result = new Result();
        List<ServiceAppointment> updates = new List<ServiceAppointment>();
        List<AssignedResource> newLinks = new List<AssignedResource>();
        // visit id + resource id pairs the new plan keeps, so the stale ones
        // can be deleted without dropping the ones being written.
        Set<String> keep = new Set<String>();
        Set<Id> touched = new Set<Id>();

        for (Stop stop : stops) {
            TimefoldRoutesExtract.Visit visit = known.get(stop.visitId);
            if (visit == null) {
                continue;                       // not part of this window
            }
            if (visit.isPinned()) {
                // Nothing to write: it is where it already was, and where a
                // person put it. Its link still has to be kept, or the stale
                // pass below would delete the very assignment that was
                // pinned. That would be a spectacular way to honour a pin.
                Id held = visit.soleResourceId();
                if (held != null) {
                    keep.add(visit.recordId + ':' + held);
                }
                result.leftPinned++;
                continue;
            }
            if (duplicated.contains(stop.engineer)) {
                result.unknownEngineers.add(stop.engineer
                    + ' (two active resources share this name)');
                continue;
            }
            Id resourceId = idOfName.get(stop.engineer);
            if (resourceId == null) {
                result.unknownEngineers.add(stop.engineer);
                continue;
            }

            Datetime start = stop.startService == null ? stop.arrival : stop.startService;
            if (start == null) {
                continue;
            }
            Datetime finish = stop.departure == null
                ? start.addMinutes(visit.durationMinutes) : stop.departure;

            updates.add(new ServiceAppointment(
                Id = visit.recordId,
                SchedStartTime = start,
                SchedEndTime = finish,
                Status = scheduledStatus));
            touched.add(visit.recordId);
            keep.add(visit.recordId + ':' + resourceId);
            result.signature.add(TimefoldRoutesExtract.placementOf(
                visit.recordId, resourceId, start));
            if (!visit.assignedResourceIds.contains(resourceId)) {
                // IsPrimaryResource is deliberately absent: the field exists
                // only when certain Field Service options are on, and Apex
                // fails to compile against a field the org does not have. The
                // link works without it.
                newLinks.add(new AssignedResource(
                    ServiceAppointmentId = visit.recordId,
                    ServiceResourceId = resourceId));
            }
            result.scheduled++;
        }

        for (String visitId : unassigned) {
            TimefoldRoutesExtract.Visit visit = known.get(visitId);
            if (visit == null || visit.isPinned()) {
                // A pinned visit should never come back unassigned, and if it
                // does, clearing it would undo the pin rather than report it.
                continue;
            }
            updates.add(new ServiceAppointment(
                Id = visit.recordId,
                SchedStartTime = null,
                SchedEndTime = null,
                Status = unscheduledStatus));
            touched.add(visit.recordId);
            result.unscheduled++;
        }

        // Clear the engineer links the new plan does not keep, before writing
        // the new ones. Without this a re-plan leaves an appointment attached
        // to two engineers and the Gantt shows the work twice.
        if (!touched.isEmpty()) {
            List<AssignedResource> stale = new List<AssignedResource>();
            for (AssignedResource row : [
                    SELECT Id, ServiceAppointmentId, ServiceResourceId
                    FROM AssignedResource
                    WHERE ServiceAppointmentId IN :touched
                    LIMIT 5000]) {
                if (!keep.contains(row.ServiceAppointmentId + ':'
                                   + row.ServiceResourceId)) {
                    stale.add(row);
                }
            }
            for (Database.DeleteResult deleted
                    : Database.delete(stale, false, AccessLevel.USER_MODE)) {
                if (deleted.isSuccess()) {
                    result.linksRemoved++;
                } else {
                    for (Database.Error error : deleted.getErrors()) {
                        result.errors.add('AssignedResource delete: '
                            + error.getStatusCode() + ': ' + error.getMessage());
                    }
                }
            }
        }

        // The appointments are updated BEFORE the links are inserted, and
        // that order is required, not tidy: Field Service refuses an
        // AssignedResource on an appointment with no schedule time -
        // "Service Appointment missing schedule time on insert or update of
        // Assign Resource". Insert the links first and every one is rejected.
        //
        // Field Service also refuses a link to a resource who is not a member
        // of the appointment's territory: "We couldn't schedule the service
        // appointment because there's no service territory member defined."
        // That is the real reason Routes.RestrictToOwnRegion defaults to true.
        // Turn it off and Timefold may move a job to a neighbouring region's
        // engineer, which is a better plan that Salesforce will not accept -
        // and it surfaces here as a refused write, not as a solver error.
        //
        // Partial success on purpose: one appointment the org refuses - a
        // validation rule, a locked record - should not throw away the rest.
        for (Database.SaveResult saved
                : Database.update(updates, false, AccessLevel.USER_MODE)) {
            if (!saved.isSuccess()) {
                result.scheduled--;
                for (Database.Error error : saved.getErrors()) {
                    result.errors.add('ServiceAppointment: '
                        + error.getStatusCode() + ': ' + error.getMessage());
                }
            }
        }
        for (Database.SaveResult saved
                : Database.insert(newLinks, false, AccessLevel.USER_MODE)) {
            if (saved.isSuccess()) {
                result.linksCreated++;
            } else {
                for (Database.Error error : saved.getErrors()) {
                    result.errors.add('AssignedResource insert: '
                        + error.getStatusCode() + ': ' + error.getMessage());
                }
            }
        }
        return result;
    }

    // ---------------------------------------------------------------- reading

    private static Map<String, Object> mapAt(Map<String, Object> source, String key) {
        if (source == null) {
            return new Map<String, Object>();
        }
        Object value = source.get(key);
        return value instanceof Map<String, Object>
            ? (Map<String, Object>) value : new Map<String, Object>();
    }

    private static List<Object> listAt(Map<String, Object> source, String key) {
        if (source == null) {
            return new List<Object>();
        }
        Object value = source.get(key);
        return value instanceof List<Object>
            ? (List<Object>) value : new List<Object>();
    }

    private static String text(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    /**
     * Read one of Timefold's timestamps.
     *
     * They come back as 2026-09-02T09:15:00Z, and sometimes with an offset or
     * fractional seconds. Datetime.valueOfGmt wants a space, not a T, so the
     * string is normalised rather than parsed by hand.
     */
    @TestVisible
    private static Datetime parse(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        String text = value.trim();
        // Drop a trailing zone: everything Timefold sends is UTC, and an
        // offset-bearing value is converted by the JSON layer before it
        // reaches here.
        if (text.endsWith('Z')) {
            text = text.substring(0, text.length() - 1);
        }
        Integer plus = text.lastIndexOf('+');
        if (plus > 10) {
            text = text.substring(0, plus);
        }
        Integer dot = text.indexOf('.');
        if (dot > 0) {
            text = text.substring(0, dot);
        }
        return Datetime.valueOfGmt(text.replace('T', ' '));
    }
}
