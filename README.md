# Timefold × Salesforce Field Service, in Apex

Plan Salesforce Field Service work with **[Timefold](https://timefold.ai)**,
directly from Apex. There is no service to host, no container and no tunnel:
the integration runs inside your org and calls the Timefold Model API.

Two Timefold models are supported:

- **Employee Shift Scheduling** assigns staff to `Shift` records (the demo
  data is a hospital nurse rota).
- **Field Service Routing** schedules and assigns `ServiceAppointment` records
  to engineers (the demo data is a London field service round).

The results are written to the standard Field Service fields, so they show in
the normal Salesforce views and in the Dispatcher Console.

## Requirements

- The [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli) (`sf`)
- `bash` and `python3`, for the setup scripts
- A Salesforce org: a Developer Edition org, or a [scratch org](#use-a-scratch-org)
- A Timefold API key. Get one free at [app.timefold.ai](https://app.timefold.ai)
  under **Settings > API keys**.

## Install

```bash
git clone https://github.com/TimefoldAI/Salesforce-Apex-integration.git
cd Salesforce-Apex-integration

cp .env.example .env          # then set TIMEFOLD_API_KEY in .env

sf org login web --alias my-org
./scripts/setup.sh --org my-org
```

`setup.sh` is idempotent and stops at the first error. It:

1. checks the Salesforce CLI and the org
2. offers to switch Field Service on, if it is off
3. offers to install the Field Service managed package (for the Dispatcher
   Console's Gantt and map; not needed to plan)
4. deploys the metadata and runs the Apex tests
5. assigns the `Timefold_Integration` permission set
6. stores the API key in the org's encrypted credential store
7. adds the two actions to the **+** menu in the Salesforce header
8. offers to seed demo data
9. calls Timefold from Apex to confirm that the key works
10. prints a link that logs you into the org

`setup.sh` reads `TIMEFOLD_API_KEY` from the environment first, then from
`.env`. You can also give the key as a flag:
`./scripts/setup.sh --org my-org --api-key ...`.

## Usage

Click the **+** in the top right of the Salesforce header and select one of
these actions:

- **Plan Roster (Timefold, Apex)**
- **Plan Routes (Timefold, Apex)**

Or start a run from a terminal:

```bash
sf apex run --file scripts/apex/optimise.apex   # both models
sf apex run --file scripts/apex/roster.apex     # only the roster
sf apex run --file scripts/apex/routes.apex     # only the routes
```

Each run is a `Timefold_Run__c` record. Open **App Launcher > Timefold Runs >
All Runs** to see status, score, travel time and errors. The **Needs
Attention** list view shows runs that did not finish. From a terminal:

```bash
sf data query -q "SELECT Name, Status__c, Solver_Status__c, Score__c, \
  Records_Written__c, Validation_Status__c, Error__c \
  FROM Timefold_Run__c ORDER BY CreatedDate DESC LIMIT 5"
```

Other scripts:

```bash
sf apex run --file scripts/apex/check.apex   # confirm the API key works
sf apex run --file scripts/apex/seed.apex    # create the demo data, or move it to this week
sf apex run --file scripts/apex/users.apex   # create Users for the demo staff
```

## Setup options

Three setup steps ask before they do something, because each one changes more
than this integration.

| Question | Default | Flags |
|---|---|---|
| Switch Field Service on? | yes | `--enable-field-service`, `--no-enable-field-service` |
| Install the Field Service managed package? | no | `--managed-package`, `--no-managed-package` |
| Seed the demo data? | yes on an empty org or an org with the demo data, otherwise no | `--seed`, `--no-seed` |

`--yes` takes the default for each question that has no flag. Without a
terminal (for example in CI), setup also takes the defaults.

```bash
./scripts/setup.sh --org my-org --enable-field-service --no-seed
./scripts/setup.sh --org my-org --yes
```

**Field Service.** The objects that the integration reads (`ServiceAppointment`,
`ServiceResource`, `ServiceTerritory`, `Shift` and others) exist only when Field
Service is on. Setup deploys the `fieldServiceOrgPref` preference from the
`field-service/` package directory. This directory is separate from
`force-app`, so a normal deploy never changes this org-wide setting. Field
Service is free, also in a Developer Edition org.

**Managed package.** The package adds the Dispatcher Console with its Gantt and
map. It is not necessary to plan. Installation takes 5 to 30 minutes and you
cannot uninstall it cleanly. The version id is set in `setup.sh` and you can
override it with `FSL_PACKAGE_VERSION`.

**Demo data.** The seeder writes demo records into the org. It does not delete
records. It can use free user licenses to create demo staff. Do not seed an org
that holds real data: the integration plans your own Field Service records. If
you do not seed, set `Routes.RootTerritory` to your territory and make sure each
engineer's `ServiceTerritoryMember` has a `Latitude` and `Longitude`.

## The API key

Setup stores the key for you when `TIMEFOLD_API_KEY` is set or `--api-key` is
given. The key is kept in the External Credential **Timefold API**, in the
org's encrypted credential store. Apex, SOQL and reports cannot read it.
`TimefoldClient` refers only to the Named Credential, and Salesforce adds the
`X-API-KEY` header.

To set the key by hand:

1. Open **Setup**, then type `Named Credentials` in **Quick Find**.
2. Click the **External Credentials** tab.
3. Click **Timefold API**.
4. In the **Principals** panel, find the row `TimefoldApiKey`. Click the
   dropdown arrow under **Actions** at the far right of the row, then **Edit**.
5. Paste the key into the **Value** of the parameter `ApiKey`.
6. Click **Save**.

Shortcut: `sf org open --target-org <alias> --path lightning/setup/NamedCredential/home`.

After you save, **Authentication Status** shows `Unknown`. This is normal for a
Custom credential. The value is masked and you cannot read it back. To test the
key, run `sf apex run --file scripts/apex/check.apex`.

## How it works

```
   Salesforce                    Apex                        Timefold
  ┌───────────┐   SOQL     ┌──────────────────┐            ┌───────────┐
  │  standard │ ─────────► │ Extract          │            │ Employee  │
  │  Field    │            │   ↓              │  X-API-KEY │ Shift     │
  │  Service  │            │ Request ─────────┼───────────►│ Scheduling│
  │  objects  │            │   ↓              │            │     or    │
  │           │ ◄───────── │ Writeback   ◄────┼────────────│ Field Svc │
  └───────────┘    DML     └──────────────────┘  queueable │  Routing  │
                                                   polling └───────────┘
```

Each model has three classes, one for each step:

| Step | Roster | Routes |
|---|---|---|
| Read Salesforce | `TimefoldRosterExtract` | `TimefoldRoutesExtract` |
| Build the Timefold request | `TimefoldRosterRequest` | `TimefoldRoutesRequest` |
| Write the result back | `TimefoldRosterWriteback` | `TimefoldRoutesWriteback` |

`TimefoldJob` runs both models. The client, the rules, the run record and the
polling are shared.

The results go to the standard fields that Salesforce scheduling also uses:

| Model | Fields written |
|---|---|
| Roster | `Shift.ServiceResourceId`, `Shift.Status` |
| Routes | `ServiceAppointment.SchedStartTime`, `SchedEndTime`, `Status`, and one `AssignedResource` for each assigned engineer |

### Runs across transactions

A solve can take a minute or more, and an Apex callout is limited to 120
seconds. So a run is split into queueable jobs, and the `Timefold_Run__c`
record keeps the state:

```
start()   creates the run record, enqueues SUBMIT
SUBMIT    extract → build → POST → store the job id → enqueue POLL
POLL      GET the metadata
            still solving?  enqueue POLL again, one minute later
            finished?       GET the solution, write it back, close the run
```

A Developer Edition org allows a chain of only five queueable jobs, so polls
are limited to three. If a run takes longer, it stops with a message. Collect
the result by hand:

```apex
TimefoldJob.collect('a0Xxx...');   // gets the solution and writes it back
```

To prevent this, decrease `Roster.SolverSeconds`. Other org editions have no
chain limit.

### Data used from Salesforce

| Timefold needs | Taken from |
|---|---|
| the engineers | `ServiceResource` in the region's `ServiceTerritoryMember` |
| their skills | `ServiceResourceSkill` |
| their start location | `ServiceTerritoryMember.Latitude` / `Longitude` |
| their working hours | `OperatingHours` and its `TimeSlot` rows |
| the job locations | `ServiceAppointment.Latitude` / `Longitude` |
| the job durations | `ServiceAppointment.Duration` / `DurationType` |
| the customer time windows | `EarliestStartTime` and `DueDate` |
| the skills a job needs | `SkillRequirement` on the parent `WorkOrder` |
| time off | `ResourceAbsence`, sent as a fixed break |
| jobs that must not move | `FSL__Pinned__c`, the status category, and the last run's plan |

Travel times and distances come from the Timefold Platform maps service. The
maps provider is a tenant setting in the Timefold Platform (**Settings > Maps
provider**). Each run stores its total travel time and distance in
`Travel_Time_Hours__c` and `Travel_Distance_Km__c`.

### Business rules

Roster:

| Rule | Source |
|---|---|
| A nurse needs the certificates for the role | `Shift.JobProfileId` → role → skills, compared with `ServiceResourceSkill` |
| A nurse works only on wards they belong to | `ServiceTerritoryMember` |
| Nobody is rostered while on leave | `ResourceAbsence` |
| Contract hours per week | `ServiceResourceCapacity.CapacityInHours` |
| Night-only staff work only nights | `OperatingHours` on their `ServiceTerritoryMember` |

Routes:

| Rule | Source |
|---|---|
| An engineer needs the skill the job requires | `SkillRequirement` on the `WorkOrder`, compared with `ServiceResourceSkill` |
| Each region's work stays with its own crew | `ServiceTerritory` hierarchy, sent as a required tag |
| The customer's arrival window | `ServiceAppointment.EarliestStartTime` and `DueDate` |
| Engineers start and finish at home | `ServiceTerritoryMember.Latitude` / `Longitude` |
| Working days and hours | `OperatingHours` on the membership |
| Lunch and other time off | `ResourceAbsence`, as a `FIXED` break on that shift |
| A full day off | `ResourceAbsence` that covers the shift: the shift is removed |
| A job that a person committed to | pinned (see below) |
| A canceled job | `StatusCategory` `Canceled`: not sent |

### Manual assignments

The routes model does not move a job that a person already committed to. A
scheduled appointment is pinned when one of these is true:

1. **`FSL__Pinned__c` is set.** A dispatcher pinned it in the console. This
   field comes from the Field Service managed package, which is optional, so it
   is read with a dynamic query.
2. **The status category is after `Scheduled`**: `Dispatched`, `In Progress`,
   `Completed` or `Cannot Complete`.
3. **Timefold did not put it there.** Each run stores its plan in
   `Timefold_Run__c.Plan_Signature__c`. A scheduled appointment whose placement
   is not in a stored plan was placed by a person. If no plan was stored yet,
   this check is skipped.

A pinned visit is sent without its time window, at its current time and
engineer. If no shift can hold a pinned visit (for example, it is outside the
engineer's working hours), the pin is removed and the run record names the
visit. Set `Routes.RespectExisting` to `false` to replan everything.

## Configuration

Labor policy and solver weights are `Timefold_Setting__c` records. Edit them in
the **All Settings**, **Roster Labour Rules** and **Solver Weights** list
views. `TimefoldRules` contains a default for each key, so the integration
works before you create any record. A record overrides one default.

| Key | Default | Notes |
|---|---|---|
| `Roster.MinimumRestHours` | `11` | UK and EU working time rules |
| `Roster.MaximumConsecutiveDays` | `5` | |
| `Roster.ContractHoursMinimumFraction` | `0.6` | Spreads work across staff. Without a minimum, the solver can staff a ward with too few people |
| `Roster.WeekendWindowWeeks` | `2` | "One weekend in two" as a rolling window |
| `Roster.SolverSeconds` | `60` | |
| `Weight.Roster.*` | | Constraint weights for the roster |
| `Routes.RootTerritory` | `St. Elmore Field Service` | The territory to plan, with all territories below it |
| `Routes.RestrictToOwnRegion` | `true` | If `false`, Timefold can assign a job to an engineer of another region, and Salesforce refuses that assignment |
| `Routes.OvertimeMinutes` | `30` | The shift end is a soft limit; this is the hard limit after it |
| `Routes.DefaultWorkDays` | `Monday;…;Friday` | Used only when a membership has no `OperatingHours` |
| `Weight.Routes.balanceTimeUtilizationWeight` | `100` | Balances work between engineers |
| `Weight.Routes.minimizeTravelDistanceWeight` | `0` | Use only one travel objective. If both are non-zero, Timefold reports `TRAVEL_WEIGHT_CONFLICT` |
| `Routes.BreaksFromAbsences` | `true` | Sends `ResourceAbsence` as breaks |
| `Routes.RespectExisting` | `true` | Pins manual assignments (see [Manual assignments](#manual-assignments)) |
| `Routes.PinnedStatusCategories` | `Dispatched;InProgress;Completed;CannotComplete` | Status categories that pin a job |

## Demo data

`TimefoldSeed` creates two datasets. It is idempotent: if you run it again,
nothing is duplicated.

- **A hospital** with three wards, nurses with certificates and contracts, a
  night rota, some leave, and two weeks of shifts.
- **A field service round** in London: a root territory, a region,
  biomedical engineers with home locations and certificates, and ten jobs as
  `WorkOrder` records with one `ServiceAppointment` each.

The size depends on the free user licenses in the org, because each
`ServiceResource` must point to a `User`. A scratch org gives two nurses and
two engineers. `Seed.ReserveForEngineers` keeps licenses free for the
engineers.

The demo appointments have coordinates and no street address. This prevents
the Salesforce geocoding rules from replacing the coordinates.

Each time the seeder runs, it moves the round to the current working week (a
weekend moves to the next Monday). Run it again when the demo data is in the
past.

`Skill` and `ServiceResource` records cannot be deleted in Salesforce. Use a
scratch org if you want to start again from nothing.

## Dispatcher Console

The integration does not need the Dispatcher Console. To see the plan on the
Gantt and the map, install the managed package during setup. Setup then also:

- grants the dispatcher license (`FieldServiceDispatcherPsl`)
- deploys and assigns the six `FSL_*` permission sets from
  `field-service-console/`
- grants `FieldServiceMobilePsl` to each seeded engineer, so that they show on
  the Gantt. A scratch org has one of these licenses and a Developer Edition
  org has two.
- switches on **Send geolocation and map data to Google and Apple**
  (`canPopulateGoogleAddress`). The **MAP** tab shows only when this setting
  is on. It lets Field Service send addresses and coordinates to Google and
  Apple.

## Troubleshooting

**Callouts return 401.** The API key is not set or is wrong. Run setup again
with `TIMEFOLD_API_KEY` set, or set the key by hand (see [The API
key](#the-api-key)).

**Tabs show "Nothing to see here".** Standard tabs open on **Recently
Viewed**. Select **All** in the list view dropdown.

**The Gantt is empty.** The console opens on the date it showed last. Click
**Today**, or go to the date of the run. If the demo data is in the past, run
the seeder again.

**A resource row on the Gantt has no appointments.** The Gantt does not show
appointments for a capacity-based `ServiceResource`. Check:

```bash
sf data query -q "SELECT Name, IsCapacityBased FROM ServiceResource WHERE IsActive = true"
```

**Every shift is unassigned, with `0hard` and a negative medium score.** No
legal assignment exists, usually because no nurse has all the skills a shift
requires. An unassigned shift costs a medium point; a missing skill costs a
hard point. Compare the shift's `requiredSkills` with each employee's `skills`
in the run's input dataset.

**A run stopped after three polls.** See [Runs across
transactions](#runs-across-transactions).

## Use a scratch org

```bash
./scripts/scratch-org.sh create      # then ./scripts/setup.sh --org timefold-apex
./scripts/scratch-org.sh recreate    # delete and create again
./scripts/scratch-org.sh open
./scripts/scratch-org.sh url         # print a login URL
./scripts/scratch-org.sh list        # existing scratch orgs and remaining allowance
./scripts/scratch-org.sh delete
```

Each command takes `--org <alias>` (or `--target-org`). The default alias is
`timefold-apex`.

You need a Dev Hub. A Developer Edition org can be one. Set
`enableScratchOrgManagementPref` to `true` in the `DevHub` settings and deploy
it:

```bash
sf project retrieve start -m "Settings:DevHub"
# set enableScratchOrgManagementPref to true, then deploy it back
sf org list --all                    # refreshes the CLI's Dev Hub status
```

A Developer Edition Dev Hub allows 3 active scratch orgs and 6 for each day.

## Tests

```bash
sf apex run test --class-names TimefoldTest --class-names TimefoldJobTest \
  --class-names TimefoldRoutesTest --code-coverage
```

Setup runs these tests during the deploy.

## Repository layout

```
force-app/main/default/
  classes/
    TimefoldClient.cls            calls the Timefold Model API
    TimefoldRosterExtract.cls     read Salesforce      ─┐
    TimefoldRosterRequest.cls     build the request     │ roster
    TimefoldRosterWriteback.cls   write the result back ─┘
    TimefoldRoutesExtract.cls     read Salesforce      ─┐
    TimefoldRoutesRequest.cls     build the request     │ routes
    TimefoldRoutesWriteback.cls   write the result back ─┘
    TimefoldJob.cls               submit, poll and finish across transactions
    TimefoldRules.cls             defaults, and the records that override them
    TimefoldSeed.cls              the demo data
    TimefoldPlanner.cls           what the + menu actions call
  objects/
    Timefold_Run__c               one run: status, score, travel, plan
    Timefold_Setting__c           the configuration
  externalCredentials/            stores the API key, encrypted
  namedCredentials/               the endpoint and the X-API-KEY header
  permissionsets/                 Timefold_Integration, for users who run plans;
                                  Timefold_Demo_Staff, for the demo staff
  skills/                         the demo certificates
  flows/, quickActions/           the two + menu actions

field-service/                    the Field Service org preference
field-service-console/            Dispatcher Console permission sets and map setting

scripts/
  setup.sh                        sets up an org
  scratch-org.sh                  creates and deletes scratch orgs
  add_global_action.py            adds the actions to the + menu
  apex/                           users, seed, check, optimise, roster, routes

config/
  project-scratch-def.json        the scratch org definition
```

## Known limits

- **Breaks are always `FIXED`.** `ResourceAbsence` has a fixed start and end.
  Timefold also supports `FLOATING` breaks, but Field Service cannot express
  them.
- **Pinning needs exactly one engineer on the appointment.** A visit with two
  `AssignedResource` rows is not pinned, and the run record names it.
- **Polls are limited to three in a Developer Edition org.** Use
  `TimefoldJob.collect(runId)` for a run that takes longer.
- **The roster extract reads every active `ServiceResource`.** Engineers cannot
  be assigned to ward shifts, because ward membership is a required skill, but
  they are in the request.
- **Apex heap and SOQL limits restrict the dataset size.** Two weeks with a few
  hundred shifts is no problem. Tens of thousands of records need batching.

## Contributing

This repository does not accept external contributions. See
[CONTRIBUTING.md](CONTRIBUTING.md) for how to report a bug or ask for a change,
and [SECURITY.md](SECURITY.md) for how to report a security problem.

## License

Apache 2.0. See [LICENSE](LICENSE).
