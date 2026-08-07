#!/usr/bin/env python3
"""Print the next build number in YYMMDD.R form, e.g. 260806.4.

R is the next unused revision, found by asking App Store Connect what has
already been uploaded rather than guessing from a local counter — CI, a laptop
and a re-run all agree that way.

    Scripts/next-build-number.py            # e.g. 260806.4

App Store Connect rejects a CFBundleVersion it has already seen, and compares
the rest component by component, so the answer has to be greater than every
YYMMDD.R uploaded so far — not merely unused today. When two machines disagree
about the date (the build runner is on Eastern time, a laptop on Pacific) the
later date wins and R carries on from there, so numbers never go backwards.

CFBundleVersion must exceed the previous one *within the same marketing
version*. Restarting at YYMMDD.R after timestamp-style numbers therefore
requires a new MARKETING_VERSION; see docs/ci-setup.md.
"""
import datetime, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asc_api

BUILD_NUMBER = re.compile(r"^(\d{6})\.(\d+)$")


def main() -> int:
    # No fallback on purpose. Guessing YYMMDD.1 when the key or the network is
    # missing looks harmless and is not: .1 is taken on any day that has seen a
    # build, so the guess turns a five-second failure into one that surfaces
    # fifteen minutes later, after a full archive, as an upload rejection.
    builds = asc_api.get(
        f"/v1/builds?filter[app]={asc_api.APP_ID}"
        "&limit=200&sort=-uploadedDate&fields[builds]=version")["data"]

    highest = (int(datetime.date.today().strftime("%y%m%d")), 0)
    for build in builds:
        match = BUILD_NUMBER.match(build["attributes"].get("version") or "")
        if match:
            highest = max(highest, (int(match[1]), int(match[2])))

    print(f"{highest[0]}.{highest[1] + 1}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
