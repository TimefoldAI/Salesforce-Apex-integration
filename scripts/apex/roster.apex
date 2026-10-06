// Start only the nurse rota.
//   sf apex run --file scripts/apex/roster.apex
Id runId = TimefoldJob.start('Roster');
System.debug(LoggingLevel.ERROR, 'RUN>' + runId
    + ' watch it with: sf data query -q "SELECT Name, Status__c, Score__c,'
    + ' Records_Written__c, Unassigned__c, Error__c FROM Timefold_Run__c'
    + ' WHERE Model__c = \'Roster\' ORDER BY CreatedDate DESC LIMIT 5"');
