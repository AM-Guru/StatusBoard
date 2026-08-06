#!/usr/bin/env python3
"""Print the next build number in YYMMDD.R form, e.g. 260806.3.

R is the next unused revision for today, found by asking App Store Connect what
has already been uploaded rather than guessing from a local counter — CI, a
laptop and a re-run all agree that way.

    Scripts/next-build-number.py            # e.g. 260806.1

CFBundleVersion is compared component by component, so a build number must
exceed the previous one *within the same marketing version*. Restarting at
YYMMDD.R after timestamp-style numbers therefore requires a new
MARKETING_VERSION; see docs/ci-setup.md.
"""
import datetime, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asc_api


def main() -> int:
    today = datetime.date.today().strftime("%y%m%d")
    highest = 0
    try:
        versions = asc_api.get(
            f"/v1/apps/{asc_api.APP_ID}/preReleaseVersions?limit=50")["data"]
        for version in versions:
            builds = asc_api.get(
                f"/v1/preReleaseVersions/{version['id']}/builds?limit=200")["data"]
            for build in builds:
                number = build["attributes"].get("version") or ""
                if not number.startswith(today + "."):
                    continue
                try:
                    highest = max(highest, int(number.split(".", 1)[1]))
                except (IndexError, ValueError):
                    continue
    except SystemExit:
        # Never block a build on the API being unreachable; 1 is the safe
        # first guess and a genuine clash still fails loudly at upload.
        print(f"{today}.1")
        return 0

    print(f"{today}.{highest + 1}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
