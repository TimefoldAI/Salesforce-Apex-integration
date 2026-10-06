#!/usr/bin/env bash
#
# Set up an org from nothing, in one command.
#
#   ./scripts/setup.sh --org my-org
#
# There is nothing to run afterwards. No service, no container, no tunnel: the
# integration is Apex, so once this finishes the org optimises on its own.
#
# What it does, stopping at the first thing that is wrong:
#
#   1. checks the Salesforce CLI and the org
#   2. offers to switch Field Service on, if it is off
#   3. offers to install the Field Service managed package, if you want the
#      Dispatcher Console's Gantt and map
#   4. grants the dispatcher licence and deploys the console's permission sets,
#      so the Dispatcher Console opens
#   5. deploys the metadata, running the Apex tests
#   6. assigns the Timefold Integration permission set
#   7. stores the API key, if you gave it one
#   8. puts the actions in the + menu in the Salesforce header
#   9. offers to seed the demo hospital and the London field service round
#  10. gives each seeded engineer the licence that puts them on the Gantt
#  11. proves the key works by calling Timefold from Apex
#  12. prints a link that logs you into the org
#
# Three of those steps ask before doing anything, because each changes more
# than this integration: Field Service is an org-wide preference, the managed
# package cannot be uninstalled cleanly, and seeding writes demo records into
# whatever org you point it at.
#
# Options:
#
#   --org <alias>                 which org; the default org otherwise
#   --api-key <key>               the Timefold API key; otherwise
#                                 TIMEFOLD_API_KEY from the environment or .env
#   --seed | --no-seed            answer the seeding question up front
#   --enable-field-service        answer the Field Service question with yes
#   --no-enable-field-service     ... or with no
#   --managed-package             install the Field Service managed package
#   --no-managed-package          ... or do not (the default)
#   --yes                         take the default answer to every question
#                                 without asking, for a script or a CI job
#
# Everything is idempotent. Run it again after changing anything.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ORG=""
SEED=""                      # "", "yes" or "no" - empty means ask
ENABLE_FS=""                 # the same
MANAGED=""                   # the same
ASSUME_DEFAULTS=0

# The Field Service managed package, published by Salesforce. Version ids move
# with each release, so this pins a known-good one. To find the current id,
# install it once from Setup > Field Service Settings > Getting Started, then:
#   sf package installed list --target-org <alias> --json
FSL_PACKAGE_VERSION="${FSL_PACKAGE_VERSION:-04tKX000000f77fYAA}"
API_KEY="${TIMEFOLD_API_KEY:-}"
if [[ -z "$API_KEY" && -f .env ]]; then
  API_KEY="$(set -a; source .env; printf '%s' "${TIMEFOLD_API_KEY:-}")"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)                      ORG="$2"; shift 2 ;;
    --api-key)                  API_KEY="$2"; shift 2 ;;
    --seed)                     SEED="yes"; shift ;;
    --no-seed)                  SEED="no"; shift ;;
    --enable-field-service)     ENABLE_FS="yes"; shift ;;
    --no-enable-field-service)  ENABLE_FS="no"; shift ;;
    --managed-package)          MANAGED="yes"; shift ;;
    --no-managed-package)       MANAGED="no"; shift ;;
    --yes|-y)                   ASSUME_DEFAULTS=1; shift ;;
    # Print the comment block above, however long it grows, and stop at the
    # first line that is not one. A fixed line range drifts out of date and
    # starts printing code.
    -h|--help)  awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' \
                  "$0"; exit 0 ;;
    *)          echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

step()  { printf '\n%s\n%s\n' "$1" "$(printf '%*s' "${#1}" '' | tr ' ' '-')"; }
ok()    { printf '  ok   %s\n' "$1"; }
skip()  { printf '  --   %s\n' "$1"; }
warn()  { printf '  !!   %s\n' "$1"; }
die()   { printf '\n%s\n' "$1" >&2; exit 1; }

# ask <question> <default: yes|no> -> 0 for yes, 1 for no
#
# Falls back to the default without asking when there is nobody to ask - a CI
# job, a pipe, --yes - because a setup script that blocks forever waiting on a
# closed stdin is worse than one that takes the safe answer.
ask() {
  local question="$1" default="$2" reply=""
  if [[ "$ASSUME_DEFAULTS" -eq 1 || ! -t 0 ]]; then
    printf '  ?    %s [%s] %s\n' "$question" "$default" \
           "$([[ "$ASSUME_DEFAULTS" -eq 1 ]] && echo "(--yes)" || echo "(not a terminal)")"
    [[ "$default" == "yes" ]] && return 0 || return 1
  fi
  while true; do
    printf '  ?    %s [%s/%s] ' "$question" \
           "$([[ "$default" == "yes" ]] && echo Y || echo y)" \
           "$([[ "$default" == "yes" ]] && echo n || echo N)"
    read -r reply || reply=""
    case "${reply:-$default}" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo])     return 1 ;;
      *) printf '       yes or no, please.\n' ;;
    esac
  done
}

# How many records of one object the org holds, or "?" if it cannot be asked.
count_of() {
  sf data query "${TARGET[@]}" -q "SELECT COUNT() FROM $1" --json 2>/dev/null \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["result"]["totalSize"])
except Exception: print("?")' 2>/dev/null || echo "?"
}

# ---------------------------------------------------------------- 1. the CLI

step "Checking the Salesforce CLI and the org"
command -v sf >/dev/null 2>&1 || die \
"The Salesforce CLI is not on PATH.
  npm install --global @salesforce/cli
  https://developer.salesforce.com/tools/salesforcecli"

TARGET=()
[[ -n "$ORG" ]] && TARGET=(--target-org "$ORG")

INFO="$(sf org display "${TARGET[@]}" --json 2>/dev/null)" || die \
"Could not reach the org${ORG:+ \"$ORG\"}.
  Authorise one first:  sf org login web --alias ${ORG:-timefold-apex}
  Then pass it:         ./scripts/setup.sh --org ${ORG:-timefold-apex}"

USERNAME="$(printf '%s' "$INFO" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["username"])')"
INSTANCE="$(printf '%s' "$INFO" | python3 -c 'import sys,json;print(json.load(sys.stdin)["result"]["instanceUrl"])')"
ok "$USERNAME at $INSTANCE"

# ------------------------------------------------------- 2. Field Service

step "Field Service"

# ServiceResource only exists once Field Service is on, so asking for it is the
# cheapest reliable test.
field_service_on() {
  sf data query "${TARGET[@]}" -q "SELECT COUNT() FROM ServiceResource" \
    >/dev/null 2>&1
}

if field_service_on; then
  ok "already on"
else
  cat <<'EOF'
  Field Service is switched off in this org, and none of the objects this
  integration reads exist until it is on: ServiceAppointment, ServiceResource,
  ServiceTerritory, Shift and the rest.

  It is free, including in a Developer Edition org, and it is an org-wide
  preference rather than anything belonging to this integration - which is why
  you are being asked rather than told. The managed package is a separate thing
  and is not needed: it adds the Dispatcher Console's Gantt and map, which are
  good to look at and not required to plan anything.

  It can be switched back off the same way, by deploying the preference as
  false, which does remove those objects again. Worth knowing before you say
  yes on an org that matters: anything stored on them goes with them.
EOF
  answer="$ENABLE_FS"
  if [[ -z "$answer" ]]; then
    ask "Switch Field Service on now?" yes && answer="yes" || answer="no"
  fi
  if [[ "$answer" != "yes" ]]; then
    die "Nothing was changed, and there is nothing this integration can do
without those objects. Either:

  turn it on in Setup > Field Service Settings, then run this again, or
  run this again with --enable-field-service"
  fi
  # Its own package directory, so "deploy the integration" never carries an
  # org-wide switch with it.
  if ! sf project deploy start "${TARGET[@]}" --source-dir field-service \
         --wait 10 >/dev/null 2>&1; then
    die "Could not switch Field Service on from metadata. See what Salesforce said:
  sf project deploy start ${TARGET[*]} --source-dir field-service

  Or turn it on by hand: Setup > Field Service Settings > Field Service."
  fi
  if field_service_on; then
    ok "switched on"
  else
    die "Salesforce accepted the preference but ServiceResource still does not
  exist. That is usually a minute of lag: wait and run this again."
  fi
fi

# ------------------------------------------------ 3. the managed package

step "The Field Service managed package"

INSTALLED="$(sf package installed list "${TARGET[@]}" --json 2>/dev/null \
  | python3 -c 'import sys,json
try: rows = json.load(sys.stdin).get("result", [])
except Exception: rows = []
print("yes" if any(r.get("SubscriberPackageNamespace") == "FSL" for r in rows) else "no")' \
  2>/dev/null || echo "no")"

FSL_PRESENT=0
if [[ "$INSTALLED" == "yes" ]]; then
  ok "already installed"
  FSL_PRESENT=1
else
  cat <<'EOF'
  Not installed, and not needed. This integration reads and writes standard
  objects only; the package adds the Dispatcher Console's Gantt and map, which
  are how you look at a plan rather than how it is made.

  Worth having if you want to see the round drawn on a map with the routes on
  it. It takes ten to thirty minutes and cannot be uninstalled cleanly, so it
  is a question and the default is no.
EOF
  answer="$MANAGED"
  if [[ -z "$answer" ]]; then
    ask "Install it now?" no && answer="yes" || answer="no"
  fi
  if [[ "$answer" != "yes" ]]; then
    skip "not installing; the + menu actions work without it"
  else
    echo "     installing ${FSL_PACKAGE_VERSION}; ten to thirty minutes."
    echo "     Salesforce emails you when it finishes, and the Setup checklist"
    echo "     often does not refresh - trust this command rather than that page."
    if sf package install --package "$FSL_PACKAGE_VERSION" "${TARGET[@]}" \
         --security-type AdminsOnly --no-prompt --wait 40; then
      ok "installed"
      FSL_PRESENT=1
    else
      warn "install failed. If the pinned version id is stale, find the current"
      warn "one from Setup > Field Service Settings > Getting Started and set"
      warn "FSL_PACKAGE_VERSION. Nothing else here depends on it."
    fi
  fi
fi

# --------------------------------------------------- 4. dispatcher access

step "Dispatcher access"

# Two separate things, and the Dispatcher Console refuses to open without both
# while telling you which of them is missing: neither.
#
#   the permission set LICENCE   FieldServiceDispatcherPsl, standard, always
#                                present once Field Service is on
#   the permission SETS          FSL_Dispatcher_License and the rest, which the
#                                managed package's Getting Started page creates
#                                and the install itself does not
#
# None of this is needed to plan anything. It is needed to look at the result.
for psl in FieldServiceStandardPsl FieldServiceDispatcherPsl; do
  HELD="$(sf data query "${TARGET[@]}" --json -q \
      "SELECT Id FROM PermissionSetLicenseAssign
       WHERE PermissionSetLicense.DeveloperName = '${psl}'
         AND Assignee.Username = '${USERNAME}'" 2>/dev/null \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["result"]["totalSize"])
except Exception: print(0)' 2>/dev/null || echo 0)"
  if [[ "$HELD" != "0" ]]; then
    ok "$psl already held"
  elif sf org assign permsetlicense --name "$psl" "${TARGET[@]}" >/dev/null 2>&1; then
    ok "$psl assigned"
  else
    warn "$psl could not be assigned: no free licence, or not in this org"
  fi
done

# The six permission sets the console needs. Salesforce's instructions say to
# click Setup > Field Service Settings > Getting Started > Permission Sets, and
# that click creates them - it does not install them from the package. They are
# org-local and custom, with no namespace, so they are ordinary metadata and
# deploy like anything else. See field-service-console/README.md.
#
# Only into an org that has the package: they reference the FSL__ objects, and
# without those the deploy fails on every one of them.
#
# The same directory carries the one setting that makes the console's MAP tab
# exist - "Send geolocation and map data to Google and Apple". It is here and
# not in field-service/ because field-service/ is deployed only on an org
# where Field Service was off, so an org that already had it on would never
# receive it.
if [[ "$FSL_PRESENT" -eq 1 ]]; then
  if sf project deploy start "${TARGET[@]}" --source-dir field-service-console \
       --wait 30 >/dev/null 2>&1; then
    ok "console permission sets deployed"
    ok "map data on, so the console has a MAP tab beside GANTT"
    echo "       that setting sends addresses and coordinates to Google and"
    echo "       Apple, which is how the map is drawn. Setup > Field Service"
    echo "       Settings > \"Send geolocation and map data to Google and"
    echo "       Apple\" switches it back off, and the tab goes with it."
  else
    warn "could not deploy the console permission sets; retry by hand with"
    warn "  sf project deploy start --source-dir field-service-console ${ORG:+--target-org $ORG}"
  fi
else
  skip "no managed package, so the console permission sets are not deployed"
fi

# Assign whatever of them the org now has.
#
# FSL_Admin_Permissions is not for the dispatcher: it is for whoever
# administers Field Service, which is whoever runs this. Without it the
# package's own Getting Started page says "Missing permissions" and greys out
# Guided Setup, and the Field Service Settings tabs are read-only - with no
# hint that a permission set is what is missing, and none of it visible from
# the command line.
FSL_SETS_FOUND=0
for ps in FSL_Dispatcher_License FSL_Dispatcher_Permissions \
          FSL_Admin_License FSL_Admin_Permissions; do
  EXISTS="$(sf data query "${TARGET[@]}" --json -q \
      "SELECT Id FROM PermissionSet WHERE Name = '${ps}'" 2>/dev/null \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["result"]["totalSize"])
except Exception: print(0)' 2>/dev/null || echo 0)"
  if [[ "$EXISTS" == "0" ]]; then
    continue
  fi
  FSL_SETS_FOUND=1
  OUT="$(sf org assign permset --name "$ps" "${TARGET[@]}" 2>&1 || true)"
  if grep -qiE 'duplicate|already' <<<"$OUT"; then
    ok "$ps already assigned"
  elif grep -qi 'error' <<<"$OUT"; then
    warn "$ps: $(tr '\n' ' ' <<<"$OUT" | cut -c1-100)"
  else
    ok "$ps assigned"
  fi
done
if [[ "$FSL_SETS_FOUND" -eq 0 ]]; then
  cat <<'EOF'
  --   none of the FSL_* permission sets is in this org
       They are deployed from field-service-console, and that only happens once
       the managed package is installed. Run this again with
       --managed-package if you want the Dispatcher Console. Everything this
       integration does works without it; the console is for looking at the
       answer, not for producing it.
EOF
fi

# ------------------------------------------------------------ 5. the metadata

step "Deploying"
# Skills first: they are a separate metadata type and the seeder needs them to
# exist, because Apex cannot create a Skill even though the REST API can.
sf project deploy start "${TARGET[@]}" --source-dir force-app --wait 30 \
  --test-level RunSpecifiedTests --tests TimefoldTest --tests TimefoldJobTest \
  --tests TimefoldRoutesTest >/dev/null \
  || die "Deploy failed. Run it again without the redirect to see what Salesforce said:
  sf project deploy start ${TARGET[*]} --source-dir force-app \\
    --test-level RunSpecifiedTests --tests TimefoldTest --tests TimefoldJobTest \\
    --tests TimefoldRoutesTest

  A coverage warning is a real failure, not a warning: Salesforce needs 75% per
  class to deploy with tests at all."
ok "metadata deployed and the Apex tests passed"

# --------------------------------------------------- 6. the permission set

step "Granting access"
if sf org assign permset "${TARGET[@]}" --name Timefold_Integration >/dev/null 2>&1; then
  ok "Timefold Integration assigned to $USERNAME"
else
  ok "Timefold Integration already assigned"
fi
warn "other users need it too, or their callouts fail with no useful message"

# ------------------------------------------------------------- 7. the API key

step "The API key"

# The External Credential uses the Custom protocol with one authentication
# parameter, ApiKey, which the Connect API can set. The Named Credential sends
# it as an X-API-KEY header.
#
# The key cannot be read back out - not by Apex, not by SOQL, not by a report -
# so it is not in this repository and not in a custom object.
if [[ -n "$API_KEY" ]]; then
  # Through a file and the environment, so the key is never an argument that
  # anybody running ps could read.
  CRED_FILE="$(mktemp)"
  chmod 600 "$CRED_FILE"
  TF_KEY="$API_KEY" python3 -c 'import json,os,sys
sys.stdout.write(json.dumps({
    "authenticationProtocol": "Custom",
    "externalCredential": "Timefold_API",
    "principalName": "TimefoldApiKey",
    "principalType": "NamedPrincipal",
    "credentials": {"ApiKey": {"value": os.environ["TF_KEY"], "encrypted": True}},
}))' > "$CRED_FILE"
  # POST creates, PUT overwrites, and the API insists you pick the right one:
  #   Authentication credentials for the principal "TimefoldApiKey" already
  #   exist. Use the PUT method to overwrite them.
  # Setting a key twice is the normal case, not the exception - anyone
  # re-running this has a key in there already - so a conflict retries as PUT.
  CRED_OUT="$(sf api request rest \
      "/services/data/v62.0/named-credentials/credential" \
      "${TARGET[@]}" --method POST --body "@${CRED_FILE}" 2>&1 || true)"
  if grep -q 'CONFLICT' <<<"$CRED_OUT"; then
    CRED_OUT="$(sf api request rest \
        "/services/data/v62.0/named-credentials/credential" \
        "${TARGET[@]}" --method PUT --body "@${CRED_FILE}" 2>&1 || true)"
  fi
  rm -f "$CRED_FILE"
  if grep -q '"principalName"' <<<"$CRED_OUT"; then
    ok "key stored in the encrypted credential store"
  else
    warn "could not store the key: $(tr -d '\n' <<<"$CRED_OUT" | cut -c1-160)"
    warn "paste it in Setup as below"
  fi
else
  cat <<'EOF'
  No key given, so nothing was stored. Either set TIMEFOLD_API_KEY in .env
  (see .env.example) and run this again, or give it directly:

    TIMEFOLD_API_KEY=... ./scripts/setup.sh          (or --api-key ...)

  or put it in by hand, which takes about thirty seconds:

    Setup > Named Credentials > External Credentials > Timefold API
    Principals > TimefoldApiKey > Edit
    Authentication Parameter  ApiKey  =  your Timefold API key
    Save

  A key is free at https://app.timefold.ai under Settings > API keys.
EOF
fi

# ------------------------------------------------- 8. the actions in the header

step "Putting the actions in the + menu"
python3 scripts/add_global_action.py ${ORG:+--org "$ORG"} || \
  warn "could not add it; the flow is deployed, so run it from Setup > Flows instead"

# ------------------------------------------------------------------ 9. seeding

step "The demo data"

SEEDED=0
answer="$SEED"

if [[ "$answer" == "no" ]]; then
  skip "not seeding (--no-seed)"
else
  # What is already here. Field Service data is the whole question: the seeder
  # creates wards, nurses, engineers, work orders and appointments, and on an
  # org that already runs on those objects that is pollution, not a demo.
  RESOURCES="$(count_of ServiceResource)"
  APPOINTMENTS="$(count_of ServiceAppointment)"
  SHIFTS="$(count_of Shift)"
  ORDERS="$(count_of WorkOrder)"
  DEMO="$(sf data query "${TARGET[@]}" --json -q \
      "SELECT COUNT() FROM ServiceTerritory WHERE Name LIKE 'St. Elmore%'" \
      2>/dev/null | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["result"]["totalSize"])
except Exception: print(0)' 2>/dev/null || echo 0)"

  printf '  This org holds %s service resource(s), %s appointment(s), %s shift(s)\n' \
         "$RESOURCES" "$APPOINTMENTS" "$SHIFTS"
  printf '  and %s work order(s).\n\n' "$ORDERS"

  # Default yes when the org is empty, or when the data that is there is this
  # demo's own - re-seeding then moves the round onto the current week, which
  # is the documented fix for a dispatcher console that looks empty. Default no
  # when there is data and it is somebody else's.
  if [[ "$DEMO" != "0" ]]; then
    printf '  The St. Elmore demo territories are already here, so seeding again\n'
    printf '  moves the round onto this week rather than adding anything.\n\n'
    DEFAULT=yes
  elif [[ "$RESOURCES" == "0" && "$APPOINTMENTS" == "0" && "$SHIFTS" == "0" \
          && "$ORDERS" == "0" ]]; then
    printf '  Nothing here yet, so there is nothing to disturb.\n\n'
    DEFAULT=yes
  else
    printf '  That is not this demo, so seeding would add St. Elmore hospital and\n'
    printf '  a London field service round alongside your own data. It deletes\n'
    printf '  nothing, but it does claim spare user licences for its nurses and\n'
    printf '  engineers, and it creates territories, work orders and shifts.\n\n'
    DEFAULT=no
  fi

  cat <<'EOF'
  Skipping this is fine. The integration reads whatever Field Service data the
  org already has: Routes.RootTerritory names the territory the round covers,
  and the roster plans whatever Shift records exist. The demo data is only a
  worked example.

EOF
  if [[ -z "$answer" ]]; then
    ask "Seed the demo hospital and the London round?" "$DEFAULT" \
      && answer="yes" || answer="no"
  fi

  if [[ "$answer" != "yes" ]]; then
    skip "not seeding; your data is untouched"
    warn "point Routes.RootTerritory at your own territory in Timefold Settings"
  else
    # Users first, and in their own transaction, because User is a setup
    # object and Apex refuses DML on a setup and a non-setup object together.
    # A scratch org arrives with licences but nobody holding them, so without
    # this the seeder builds a hospital with no nurses in it.
    OUT="$(sf apex run "${TARGET[@]}" --file scripts/apex/users.apex 2>&1 || true)"
    LINE="$(printf '%s' "$OUT" | grep -oE 'USERS>.*' | tail -1 | sed 's/^USERS>//')"
    [[ -n "$LINE" ]] && ok "$LINE" \
      || warn "could not create demo users; the seeder will use what is there"

    cat > /tmp/tf-seed.apex <<'APEX'
System.debug(LoggingLevel.ERROR, 'SEED>' + TimefoldSeed.run());
APEX
    OUT="$(sf apex run "${TARGET[@]}" --file /tmp/tf-seed.apex 2>&1 || true)"
    LINE="$(printf '%s' "$OUT" | grep -oE 'SEED>.*' | tail -1 | sed 's/^SEED>//')"
    if [[ -n "$LINE" ]]; then
      ok "$LINE"
      SEEDED=1
    else
      warn "the seeder produced no report; run it by hand to see why:"
      warn "  sf apex run --file scripts/apex/seed.apex"
    fi
  fi
fi

# ------------------------------------------------- 10. the Gantt's own licence

# The Dispatcher Console lists a service resource only when the User behind it
# holds the Field Service Resource licence. Without it the Gantt has no rows at
# all - no message, no empty state, just nothing - however correct the
# territory membership, operating hours and appointments are.
#
# There are few of these licences: one in a scratch org, two in a Developer
# Edition. That is enough for the field service engineers, which is what the
# Gantt draws. The nurse rota is Shift records, which the Gantt does not show
# at any licence count.
step "The Gantt's own licence"

# The engineers first, because the licences run out. There is one in a scratch
# org, and handing it to a nurse leaves the Gantt with no rows - which is the
# exact failure the licence exists to prevent. It happened: the first run of
# this step gave the single licence to the admin, who backs a nurse, and the
# two London engineers got nothing.
ROOT_TERRITORY="$(sf data query "${TARGET[@]}" --json -q \
    "SELECT Value__c FROM Timefold_Setting__c
     WHERE Name = 'Routes.RootTerritory'" 2>/dev/null \
  | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["result"]["records"][0]["Value__c"])
except Exception: print("St. Elmore Field Service")' 2>/dev/null \
  || echo "St. Elmore Field Service")"

usernames_from() {
  python3 -c 'import sys,json
try: rows = json.load(sys.stdin)["result"]["records"]
except Exception: rows = []
out = []
for r in rows:
    node = r
    for step in sys.argv[1:-1]:
        node = (node or {}).get(step) or {}
    u = node.get(sys.argv[-1])
    if u and u not in out:
        out.append(u)
print("\n".join(out))' "$@" 2>/dev/null || true
}

ENGINEER_USERS="$(sf data query "${TARGET[@]}" --json -q \
    "SELECT ServiceResource.RelatedRecord.Username FROM ServiceTerritoryMember
     WHERE ServiceResource.IsActive = TRUE
       AND ServiceResource.RelatedRecordId != NULL
       AND (ServiceTerritory.Name = '${ROOT_TERRITORY}'
            OR ServiceTerritory.ParentTerritory.Name = '${ROOT_TERRITORY}')" \
    2>/dev/null | usernames_from ServiceResource RelatedRecord Username)"

OTHER_USERS="$(sf data query "${TARGET[@]}" --json -q \
    "SELECT RelatedRecord.Username FROM ServiceResource
     WHERE IsActive = TRUE AND RelatedRecordId != NULL" 2>/dev/null \
  | usernames_from RelatedRecord Username)"

# Engineers, then everyone else, each name once.
RESOURCE_USERS="$(printf '%s\n%s\n' "$ENGINEER_USERS" "$OTHER_USERS" \
  | awk 'NF && !seen[$0]++')"
ENGINEER_COUNT="$(printf '%s' "$ENGINEER_USERS" | awk 'NF' | wc -l | tr -d ' ')"

if [[ -z "$RESOURCE_USERS" ]]; then
  skip "no user-backed service resources yet; seed the data first"
else
  # Collected first: a read loop would swallow the CLI's stdin.
  GRANTED=0
  while IFS= read -r RUSER; do
    [[ -z "$RUSER" ]] && continue
    # Both fail harmlessly when the user already holds it, and reporting a
    # failure here would be reporting the wrong thing.
    sf org assign permsetlicense --name FieldServiceMobilePsl \
      --on-behalf-of "$RUSER" "${TARGET[@]}" </dev/null >/dev/null 2>&1 || true
    for ps in FSL_Resource_License FSL_Resource_Permissions; do
      sf org assign permset --name "$ps" --on-behalf-of "$RUSER" \
        "${TARGET[@]}" </dev/null >/dev/null 2>&1 || true
    done
    GRANTED=$((GRANTED + 1))
  done <<< "$RESOURCE_USERS"

  # Report who holds it, not who was newly granted it: re-assigning to somebody
  # who already has it reports an error that means nothing.
  #
  # Counted by comparing usernames rather than with a semi-join. A subquery
  # cannot select a cross-object path - AssigneeId IN (SELECT
  # ServiceResource.RelatedRecordId FROM ServiceTerritoryMember) is rejected.
  HOLDERS="$(sf data query "${TARGET[@]}" --json -q \
      "SELECT Assignee.Username FROM PermissionSetLicenseAssign
       WHERE PermissionSetLicense.DeveloperName = 'FieldServiceMobilePsl'" \
      2>/dev/null | usernames_from Assignee Username)"
  HOLDING="$(printf '%s\n' "$HOLDERS" | awk 'NF' | wc -l | tr -d ' ')"
  ENGINEERS_HOLDING="$(printf '%s\n' "$ENGINEER_USERS" | awk 'NF' | sort \
    | comm -12 - <(printf '%s\n' "$HOLDERS" | awk 'NF' | sort) \
    | awk 'NF' | wc -l | tr -d ' ')"

  # The engineers are reported separately because they are the ones the Gantt
  # draws: "1 of 5" reads like a failure when the 1 is the engineer who counts.
  ok "${ENGINEERS_HOLDING} of ${ENGINEER_COUNT} engineer(s) hold FieldServiceMobilePsl"
  ok "${HOLDING} resource user(s) hold it in total"
  if (( ENGINEERS_HOLDING < ENGINEER_COUNT )); then
    warn "the other engineers have no licence left and will not appear on the"
    warn "Gantt. A scratch org has one of these and a Developer Edition two."
    warn "The nurse rota is Shift records, which the Gantt never draws at any"
    warn "licence count, so the nurses losing out costs nothing."
  fi
fi

# ----------------------------------------------------------------- 11. proof

step "Checking Timefold answers"
cat > /tmp/tf-check.apex <<'APEX'
try {
    System.debug(LoggingLevel.ERROR, 'WHOAMI>ok ' + JSON.serialize(TimefoldClient.aboutMe()).left(160));
} catch (Exception e) {
    System.debug(LoggingLevel.ERROR, 'WHOAMI>failed ' + e.getMessage().left(300));
}
APEX
OUT="$(sf apex run "${TARGET[@]}" --file /tmp/tf-check.apex 2>&1 || true)"
LINE="$(printf '%s' "$OUT" | grep -oE 'WHOAMI>.*' | tail -1 | sed 's/^WHOAMI>//')"
case "$LINE" in
  ok*)     ok "Timefold answered: ${LINE#ok }" ;;
  failed*) warn "${LINE#failed }" ;;
  *)       warn "no answer; run scripts/apex/check.apex by hand" ;;
esac

# ------------------------------------------------------------------- and then

step "Ready"
cat <<EOF
  In Salesforce, click the + in the top right of the header. Two actions are
  there, and neither needs a record selected:

    Plan Roster (Timefold, Apex)   replans the whole nurse rota
    Plan Routes (Timefold, Apex)   replans the whole field service round

  Watch it happen:   the Timefold Runs tab, list view "All Runs", or
                     sf data query --target-org ${ORG:-<alias>} \\
                       -q "SELECT Name, Model__c, Status__c, Score__c, Travel_Time_Hours__c FROM Timefold_Run__c ORDER BY CreatedDate DESC"

  Both answers land on the standard fields Salesforce's own scheduling writes,
  so they show up in the ordinary views with nothing custom:

    the rota   Shift.ServiceResourceId and Shift.Status
    the round  ServiceAppointment.SchedStartTime / SchedEndTime / Status,
               plus one AssignedResource per engineer on an appointment

  The round leaves alone anything a person has committed to: a job pinned in
  the console, one already dispatched, and one scheduled by hand rather than by
  the last run. The run record says how many and why.

  Three traps in the dispatcher console, all of which make a correct plan look
  like a failure and none of which reports anything: every standard tab opens
  on "Recently Viewed" rather than "All", the Gantt opens on the date it last
  showed rather than the plan's date, and a capacity-based ServiceResource gets
  no appointment bars at all. The README has the detail.
EOF

if [[ "$SEEDED" -eq 0 ]]; then
  cat <<'EOF'

  No demo data was seeded, so both actions will plan your own records. Two
  things to check before the first run:

    Timefold Settings > All Settings > Routes.RootTerritory
      the territory the round covers. Everything under it is in scope, so one
      root name is enough however many regions hang off it.

    each engineer's ServiceTerritoryMember needs Latitude and Longitude
      that is their home base, and an engineer without one is left out of the
      request and named on the run record.

  Seed the worked example later if you want one:
    sf apex run --file scripts/apex/seed.apex
EOF
fi

# ------------------------------------------------------------ 12. the way in

step "Log in"
# Neither of the two URLs to hand does this. The one sf prints when it creates
# a scratch org belongs to the Dev Hub and describes the org; the one in
# sf org display is the org's domain and stops at a login form. A frontdoor
# link carries the session, so the browser arrives already logged in.
#
# Single use, and it expires, which is why it is made here at the end rather
# than written down anywhere.
if LOGIN_URL="$(sf org open "${TARGET[@]}" --url-only --json 2>/dev/null \
    | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)["result"]["url"])
except Exception:
    sys.exit(1)')"; then
  printf '  %s\n\n' "$LOGIN_URL"
  echo "  That link logs you in. It works once and then expires. For another:"
  echo "    sf org open${ORG:+ --target-org $ORG}                 opens a browser"
  echo "    sf org open${ORG:+ --target-org $ORG} --url-only      prints a new link"
else
  warn "could not make a login link. Open the org with:"
  warn "  sf org open${ORG:+ --target-org $ORG}"
fi
