// Start only the field service round.
//   sf apex run --file scripts/apex/routes.apex
Id runId = TimefoldJob.start('Routes');
System.debug(LoggingLevel.ERROR, 'RUN>' + runId
    + ' watch it with: sf data query -q "SELECT Name, Status__c, Score__c,'
    + ' Records_Written__c, Unassigned__c, Travel_Time_Hours__c,'
    + ' Travel_Distance_Km__c, Error__c FROM Timefold_Run__c'
    + ' WHERE Model__c = \'Routes\' ORDER BY CreatedDate DESC LIMIT 5"');
