// Create or top up the demo hospital. Idempotent.
//   sf apex run --file scripts/apex/seed.apex
System.debug(LoggingLevel.ERROR, 'SEED>' + TimefoldSeed.run());
