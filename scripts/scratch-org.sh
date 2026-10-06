#!/usr/bin/env bash
# Disposable Salesforce orgs, for trying this without consequences.
#
#   ./scripts/scratch-org.sh create     a fresh org, then run setup.sh
#   ./scripts/scratch-org.sh recreate   delete and create again, a clean slate
#   ./scripts/scratch-org.sh delete     throw it away
#   ./scripts/scratch-org.sh list       what exists now, and how many are left
#   ./scripts/scratch-org.sh open       open it in a browser
#   ./scripts/scratch-org.sh url        print a login URL instead of opening
#
# Every command takes --org <alias>, the same as setup.sh does, and defaults to
# timefold-apex. SF_ORG_ALIAS works too.
#
#   ./scripts/scratch-org.sh open --org timefold-apex-demo
#
# Why bother: a seeding run that went wrong leaves records behind, and
# ServiceResource and Skill cannot be deleted at all, whatever permissions you
# hold. A scratch org is thrown away and rebuilt in two minutes, which is the
# only genuinely clean slate Salesforce offers.
#
# The definition in config/project-scratch-def.json does not ask for the
# FieldService feature, but a Developer Edition scratch org arrives with
# fieldServiceOrgPref already true. So `create` switches it back off before
# handing the org over, and setup.sh switches Field Service on, as it would on
# any org where it is off.
#
# You need a Dev Hub. Any Developer Edition org can be one:
#   Setup -> quick-find "Dev Hub" -> enable
#   sf org login web --alias devhub --set-default-dev-hub
#
# Or, since it is only an org preference, deploy it:
#   sf project retrieve start -m "Settings:DevHub"        see the current shape
#   ... set enableScratchOrgManagementPref to true, then deploy it back
# Note the name: enableDevHub is not a field the Metadata API accepts, and the
# error it gives - "invalid at this location in type
# DeclarativeMetadataForSettings" - does not hint at the right one.
#
# A Developer Edition Dev Hub allows 3 active scratch orgs and 6 a day.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALIAS="${SF_ORG_ALIAS:-timefold-apex}"
DEVHUB="${SF_DEVHUB_ALIAS:-}"
DAYS="${SF_SCRATCH_DAYS:-7}"
DEF="${ROOT}/config/project-scratch-def.json"

COMMAND="${1:-help}"
[[ $# -gt 0 ]] && shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    # --target-org as well, because that is what every sf command calls it.
    --org|--target-org)  ALIAS="$2"; shift 2 ;;
    --days)              DAYS="$2"; shift 2 ;;
    --dev-hub)           DEVHUB="$2"; shift 2 ;;
    -h|--help)           COMMAND="help"; shift ;;
    *)                   printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
fail() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

command -v sf >/dev/null 2>&1 || fail "The Salesforce CLI is not installed.
  npm install --global @salesforce/cli"

devhub_flag() {
  [[ -n "$DEVHUB" ]] && printf -- '--target-dev-hub %s' "$DEVHUB"
}

# A link that arrives logged in.
#
# The URL sf prints when it creates an org looks like the org and is not: it is
# the Dev Hub's ScratchOrgInfo record, on the Dev Hub's domain, and opening it
# shows you a description of the org rather than the org. The way in is a
# frontdoor link, which carries the session with it.
#
# It is single use and expires, so it is made on demand and written down
# nowhere. Anyone who wants another asks for another.
login_url() {
  sf org open --target-org "$1" --url-only --json 2>/dev/null \
    | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin)["result"]["url"])
except Exception:
    sys.exit(1)'
}

require_devhub() {
  [[ -n "$DEVHUB" ]] && return
  sf config get target-dev-hub --json 2>/dev/null | grep -q '"value": "' && return
  fail "No Dev Hub is set. Enable Dev Hub in a Developer Edition org, then:
  sf org login web --alias devhub --set-default-dev-hub
Or set SF_DEVHUB_ALIAS to an org you have already authorised.
See the notes at the top of this script for doing it from metadata."
}

case "$COMMAND" in

  create)
    require_devhub
    bold "Creating scratch org '${ALIAS}', good for ${DAYS} days"
    echo "  Two minutes or so. Field Service is left off on purpose: setup.sh"
    echo "  offers to switch it on, which is the path worth testing."
    # shellcheck disable=SC2046
    sf org create scratch --definition-file "$DEF" --alias "$ALIAS" \
       --duration-days "$DAYS" --set-default --wait 20 $(devhub_flag) \
      || fail "Could not create it. Check what is left:
  sf org list limits $(devhub_flag)
A Developer Edition Dev Hub allows 3 active scratch orgs and 6 a day."

    # A scratch org runs in Pacific time whoever makes it, and the demo is a
    # London hospital with a London round. The plan is built in GMT, so on a
    # Pacific org the Gantt draws an 08:00 start at 1 AM - correct, and it
    # reads like a mistake. Disposable orgs only; setup.sh never touches this,
    # because changing somebody's timezone in a real org would be rude.
    if sf data update record --target-org "$ALIAS" --sobject User \
         --where "Username='$(sf org display --target-org "$ALIAS" --json \
           | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["username"])')'" \
         --values "TimeZoneSidKey=Europe/London LocaleSidKey=en_GB" \
         >/dev/null 2>&1; then
      echo "  Timezone set to Europe/London, which is where the demo is."
    else
      warn "  Could not set the timezone; the Gantt will draw GMT times in Pacific."
    fi

    # Field Service off, so setup.sh has to switch it on. See the note above.
    OFF="${ROOT}/.field-service-off/settings"
    mkdir -p "$OFF"
    cat > "${OFF}/FieldService.settings-meta.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<FieldServiceSettings xmlns="http://soap.sforce.com/2006/04/metadata">
    <fieldServiceOrgPref>false</fieldServiceOrgPref>
</FieldServiceSettings>
XML
    if sf project deploy start --target-org "$ALIAS" --source-dir "$OFF" \
         --ignore-conflicts --wait 10 >/dev/null 2>&1; then
      echo "  Field Service switched off, so setup.sh has to switch it on."
    else
      warn "  Could not switch Field Service off; setup.sh will find it already on."
    fi
    rm -rf "${ROOT}/.field-service-off"

    echo
    bold "Log in"
    if URL="$(login_url "$ALIAS")"; then
      echo "  ${URL}"
      echo
      echo "  That link logs you in. It works once and then expires; make"
      echo "  another with ./scripts/scratch-org.sh url --org ${ALIAS}"
    else
      warn "  Could not make a login link."
      echo "  ./scripts/scratch-org.sh open --org ${ALIAS} opens it instead."
    fi

    echo
    bold "Next"
    echo "  ./scripts/setup.sh --org ${ALIAS}"
    echo "  ./scripts/scratch-org.sh open --org ${ALIAS}"
    ;;

  delete)
    bold "Deleting scratch org '${ALIAS}'"
    sf org delete scratch --target-org "$ALIAS" --no-prompt \
      || warn "  Nothing to delete, or it was already gone."
    ;;

  recreate)
    bold "Recreating '${ALIAS}' from nothing"
    sf org delete scratch --target-org "$ALIAS" --no-prompt >/dev/null 2>&1 \
      || echo "  (nothing to delete)"
    # One command: exec replaces this process, so anything on a second line
    # without a continuation would never run and the flag would vanish.
    exec "${BASH_SOURCE[0]}" create --org "$ALIAS" --days "$DAYS" \
        ${DEVHUB:+--dev-hub "$DEVHUB"}
    ;;

  open)
    sf org open --target-org "$ALIAS"
    ;;

  url)
    login_url "$ALIAS" || fail "Could not make a login link for '${ALIAS}'.
Check the org is still there: ./scripts/scratch-org.sh list"
    ;;

  list)
    bold "Orgs"
    sf org list
    echo
    if [[ -n "$DEVHUB" ]] \
       || sf config get target-dev-hub --json 2>/dev/null | grep -q '"value": "'; then
      bold "Dev Hub allowances"
      # shellcheck disable=SC2046
      sf org list limits $(devhub_flag) 2>/dev/null \
        | grep -iE 'scratch|Name|----' || true
    fi
    ;;

  *)
    awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"
    ;;
esac
