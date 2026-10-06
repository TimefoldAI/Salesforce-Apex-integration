// Prove the API key works, without solving anything.
//   sf apex run --file scripts/apex/check.apex
try {
    System.debug(LoggingLevel.ERROR,
        'WHOAMI>ok ' + JSON.serialize(TimefoldClient.aboutMe()).left(200));
} catch (Exception e) {
    System.debug(LoggingLevel.ERROR, 'WHOAMI>failed ' + e.getMessage().left(400));
}
