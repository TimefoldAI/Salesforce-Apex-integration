// Start a run from the command line, the same way the buttons do.
//   sf apex run --file scripts/apex/optimise.apex
//
// Both models, one after the other. TimefoldJob.start refuses a second run of
// the same model while one is in flight, so this is safe to repeat; the two
// models are independent and can solve at the same time.
for (String model : new List<String>{ 'Roster', 'Routes' }) {
    System.debug(LoggingLevel.ERROR, 'RUN>' + model + ' ' + TimefoldJob.start(model));
}
System.debug(LoggingLevel.ERROR, 'RUN>watch it with: sf data query -q "SELECT Name,'
    + ' Model__c, Status__c, Solver_Status__c, Score__c, Records_Written__c,'
    + ' Travel_Time_Hours__c, Error__c FROM Timefold_Run__c'
    + ' ORDER BY CreatedDate DESC LIMIT 5"');
