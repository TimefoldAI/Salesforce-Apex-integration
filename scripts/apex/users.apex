// Create Users for the demo staff, from whatever licences the org has.
//   sf apex run --file scripts/apex/users.apex
//
// Its own script, and its own transaction, because it has to be: User is a
// setup object and Apex refuses DML on a setup and a non-setup object in one
// transaction, in either order. Run this before scripts/apex/seed.apex.
//
// A scratch org arrives with licences but nobody holding them - one admin and
// four spare Salesforce or Platform licences - so without this the seeder
// finds no spare user and builds a hospital with no nurses in it.
System.debug(LoggingLevel.ERROR, 'USERS>' + TimefoldSeed.ensureDemoUsers());
