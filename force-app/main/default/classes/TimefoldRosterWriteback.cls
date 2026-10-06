/**
 * Step three of the roster: where does the answer go?
 *
 * Onto Shift.ServiceResourceId and Shift.Status - the same standard fields
 * Salesforce's own Workforce Engagement writes. Write there and the roster
 * appears in the ordinary Shifts views with no custom object, no custom field
 * and no Lightning component.
 */
public with sharing class TimefoldRosterWriteback {

    public class Result {
        public Integer assigned = 0;
        public Integer cleared = 0;
        public Integer unchanged = 0;
        public Set<String> unknownEmployees = new Set<String>();
        public List<String> errors = new List<String>();

        public Integer written() {
            return assigned + cleared;
        }
    }

    /**
     * Salesforce Shift id -> the employee Timefold put on it, or null.
     *
     * Timefold identifies employees by the id given in the request, which is
     * the resource's Name. The mapping back to a record id happens in apply().
     */
    public static Map<String, String> assignmentsFrom(Map<String, Object> response) {
        Map<String, String> out = new Map<String, String>();
        Object output = response.get('modelOutput');
        if (!(output instanceof Map<String, Object>)) {
            return out;
        }
        Object shifts = ((Map<String, Object>) output).get('shifts');
        if (!(shifts instanceof List<Object>)) {
            return out;
        }
        for (Object item : (List<Object>) shifts) {
            Map<String, Object> shift = (Map<String, Object>) item;
            Object employee = shift.get('employee');
            // The model returns a bare employee id. Tolerate an object form
            // too, so a future shape change does not silently clear a roster.
            if (employee instanceof Map<String, Object>) {
                employee = ((Map<String, Object>) employee).get('id');
            }
            out.put(String.valueOf(shift.get('id')),
                    employee == null ? null : String.valueOf(employee));
        }
        return out;
    }

    public static Result apply(TimefoldRosterExtract.Problem problem,
                               Map<String, String> assignments) {
        String assignedStatus = TimefoldRules.text('Roster.AssignedStatus');
        String unassignedStatus = TimefoldRules.text('Roster.UnassignedStatus');
        Boolean clearUnassigned = TimefoldRules.flag('Roster.ClearUnassigned');

        Map<String, Id> idOfName = new Map<String, Id>();
        for (TimefoldRosterExtract.Nurse nurse : problem.nurses) {
            idOfName.put(nurse.name, nurse.recordId);
        }
        Map<Id, TimefoldRosterExtract.ShiftDemand> current =
            new Map<Id, TimefoldRosterExtract.ShiftDemand>();
        for (TimefoldRosterExtract.ShiftDemand demand : problem.shifts) {
            current.put(demand.recordId, demand);
        }

        Result result = new Result();
        List<Shift> updates = new List<Shift>();

        for (String shiftId : assignments.keySet()) {
            TimefoldRosterExtract.ShiftDemand demand = current.get((Id) shiftId);
            if (demand == null) {
                continue;                       // not part of this window
            }
            String employeeName = assignments.get(shiftId);

            if (String.isNotBlank(employeeName)) {
                Id resourceId = idOfName.get(employeeName);
                if (resourceId == null) {
                    // Timefold answered with somebody this org does not have.
                    // Recorded rather than guessed at: silently dropping it
                    // would look like an unfillable shift.
                    result.unknownEmployees.add(employeeName);
                    continue;
                }
                if (demand.assignedResourceId == resourceId
                        && demand.status == assignedStatus) {
                    result.unchanged++;
                    continue;
                }
                updates.add(new Shift(Id = demand.recordId,
                                      ServiceResourceId = resourceId,
                                      Status = assignedStatus));
                result.assigned++;
            } else if (clearUnassigned) {
                if (demand.assignedResourceId == null
                        && demand.status == unassignedStatus) {
                    result.unchanged++;
                    continue;
                }
                updates.add(new Shift(Id = demand.recordId,
                                      ServiceResourceId = null,
                                      Status = unassignedStatus));
                result.cleared++;
            } else {
                result.unchanged++;
            }
        }

        // Partial success on purpose: one shift the org refuses - a validation
        // rule, a locked record - should not throw away the other 335.
        for (Database.SaveResult saved
                : Database.update(updates, false, AccessLevel.USER_MODE)) {
            if (!saved.isSuccess()) {
                for (Database.Error error : saved.getErrors()) {
                    result.errors.add(error.getStatusCode() + ': ' + error.getMessage());
                }
            }
        }
        if (!result.errors.isEmpty()) {
            // Any refusal means the reported count is wrong, so correct it.
            result.assigned -= result.errors.size();
        }
        return result;
    }
}
