#!/usr/bin/env python3
"""Put the Timefold action in the + menu in the Salesforce header.

The global publisher layout is org-wide and already holds a dozen standard
actions, so this reads it, prepends ours if it is missing, renumbers the rest
and deploys it back. Running it twice changes nothing.

Not shipped as a metadata file for the same reason: deploying one would throw
away whatever the target org already had in that menu.

Two things worth knowing:

  * An absent <platformActionList> in a layout deploy means "leave it alone",
    not "clear it", and an empty one means "no actions at all". Removing an
    action needs the list deployed without it.
  * The quickActionList beside it is the Salesforce Classic publisher and
    refuses a Flow action outright: "You can't add QuickActionType Flow to a
    QuickActionList." Only platformActionList is touched.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

GLOBAL_LAYOUT = "Global-Global Layout"
ACTIONS = ["Timefold_Plan_Roster", "Timefold_Plan_Routes"]

# What to fall back to when an org's own quickActionList turns out not to be
# deployable as a platform action list. These four exist in every org.
KNOWN_GOOD = ["NewEvent", "NewTask", "NewContact", "LogACall"]


def with_new_action_list(text: str, ours: list[str],
                         standard: list[str]) -> str:
    """A whole platformActionList, ours first, then whatever else was there."""
    rows = []
    for index, action in enumerate(ours + standard):
        rows.append(
            "        <platformActionListItems>\n"
            f"            <actionName>{action}</actionName>\n"
            "            <actionType>QuickAction</actionType>\n"
            f"            <sortOrder>{index}</sortOrder>\n"
            "        </platformActionListItems>\n")
    block = ("    <platformActionList>\n"
             "        <actionListContext>Global</actionListContext>\n"
             + "".join(rows)
             + "    </platformActionList>\n")
    return text.replace("</Layout>", block + "</Layout>")


def sf(args: list[str], cwd: pathlib.Path | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(["sf", *args], capture_output=True, text=True, cwd=cwd)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--org", help="the sf org alias; the default org otherwise")
    args = parser.parse_args()
    target = ["--target-org", args.org] if args.org else []

    if not shutil.which("sf"):
        print("The Salesforce CLI is not on PATH.", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="tf-layout-") as tmp:
        project = pathlib.Path(tmp)
        (project / "sfdx-project.json").write_text(json.dumps(
            {"packageDirectories": [{"path": "force-app", "default": True}],
             "namespace": "", "sourceApiVersion": "62.0"}))
        (project / "force-app" / "main" / "default").mkdir(parents=True)

        got = sf(["project", "retrieve", "start", *target,
                  "-m", f"Layout:{GLOBAL_LAYOUT}"], cwd=project)
        if got.returncode != 0:
            print("  !!   could not retrieve the global publisher layout:",
                  (got.stdout or got.stderr).strip()[-300:], file=sys.stderr)
            return 1

        path = (project / "force-app" / "main" / "default" / "layouts"
                / f"{GLOBAL_LAYOUT}.layout-meta.xml")
        if not path.exists():
            print(f"  !!   this org has no {GLOBAL_LAYOUT}", file=sys.stderr)
            return 1

        text = path.read_text()
        missing = [a for a in ACTIONS
                   if f"<actionName>{a}</actionName>" not in text]
        if not missing:
            print("  ok   already in the + menu")
            return 0

        items = "".join(
            "        <platformActionListItems>\n"
            f"            <actionName>{action}</actionName>\n"
            "            <actionType>QuickAction</actionType>\n"
            f"            <sortOrder>{i}</sortOrder>\n"
            "        </platformActionListItems>\n"
            for i, action in enumerate(missing))

        anchor = "        <platformActionListItems>"
        head, sep, tail = text.partition(anchor)
        if sep:
            # Ours go first, so they are visible without expanding the menu.
            tail = re.sub(r"<sortOrder>(\d+)</sortOrder>",
                          lambda m: f"<sortOrder>{int(m.group(1)) + len(missing)}</sortOrder>",
                          sep + tail)
            path.write_text(head + items + tail)
            attempts = [None]
        else:
            # A new org has no platformActionList at all - only the Classic
            # quickActionList - and an absent one means "show the predefined
            # default", not "show nothing". So one has to be created, and it
            # has to carry the actions the org already shows: a list holding
            # only ours would take New Event, New Task and the rest away.
            standard = re.findall(r"<quickActionName>([^<]+)</quickActionName>",
                                  text)
            attempts = [standard, KNOWN_GOOD, []]

        for extra in attempts:
            if extra is not None:
                path.write_text(with_new_action_list(text, missing, extra))
            # Relative to the temporary project, not absolute: on macOS the
            # temp dir is /var/... while the CLI resolves the project root to
            # /private/var/..., and an absolute path then becomes a relative
            # one full of ".." that the CLI rejects as unsafe.
            pushed = sf(["project", "deploy", "start", *target,
                         "--source-dir", "force-app/main/default/layouts",
                         "--wait", "15"],
                        cwd=project)
            if pushed.returncode == 0:
                if extra == []:
                    print("  !!   the + menu now holds only the Timefold actions;"
                          " Salesforce refused the standard ones alongside them")
                break
            if extra is attempts[-1]:
                print("  !!   could not deploy the layout:",
                      (pushed.stdout or pushed.stderr).strip()[-400:],
                      file=sys.stderr)
                return 1

    print(f"  ok   added {', '.join(missing)} to the + menu")
    return 0


if __name__ == "__main__":
    sys.exit(main())
