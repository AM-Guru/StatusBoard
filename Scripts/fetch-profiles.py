#!/usr/bin/env python3
"""Install the App Store provisioning profiles this project signs with, and check them.

Release builds sign manually, so the profiles have to be on disk before xcodebuild
runs. Fetching them from App Store Connect at build time — rather than carrying
each one as a base64 secret — means a renewed profile is picked up automatically
and there is nothing extra to rotate.

Every installed profile is then checked against the entitlements project.yml asks
its targets to sign with. xcodebuild makes the same check, but only after clean,
package resolution and a dependency graph — a quarter of an hour in, on a good
day. Failing here says the same thing in seconds, and names the one command that
fixes it.

    ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_PRIVATE_KEY_PATH=... Scripts/fetch-profiles.py

Standard library only: the build machine has no third-party Python.
"""
import base64
import os
import sys

import asc_api
import signing_spec

PREFIX = "Status Board "          # only this project's profiles
DEST = os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles")


def main():
    requirements = signing_spec.load()

    profiles = asc_api.get("/v1/profiles?limit=200")["data"]

    os.makedirs(DEST, exist_ok=True)
    installed = {}
    for profile in profiles:
        attrs = profile["attributes"]
        if not attrs["name"].startswith(PREFIX):
            continue
        if attrs.get("profileState") != "ACTIVE":
            print(f"  ! skipping {attrs['name']} ({attrs.get('profileState')})")
            continue
        content = base64.b64decode(attrs["profileContent"])
        path = os.path.join(DEST, f"{attrs['uuid']}.mobileprovision")
        with open(path, "wb") as out:
            out.write(content)
        print(f"  ✓ {attrs['name']}  ({attrs['profileType']})")
        installed.setdefault(attrs["name"], []).append(content)

    if not installed:
        print(f"fetch-profiles: no ACTIVE profiles named '{PREFIX}*'", file=sys.stderr)
        return 1
    print(f"  installed {len(installed)} profile(s) into {DEST}")

    # Each named profile has to exist and carry every capability-backed entitlement
    # its targets declare. A profile is a snapshot of its App ID taken when it was
    # issued, so an entitlement added since is simply not in it.
    problems = []
    for name, requirement in sorted(requirements.items()):
        contents = installed.get(name)
        if not contents:
            problems.append(f"{name}: not installed — no ACTIVE profile by that name")
            continue
        shortfalls = [signing_spec.missing_entitlements(requirement, content)
                      for content in contents]
        if all(shortfalls):
            problems.append(
                f"{name}: does not carry {', '.join(shortfalls[0])} "
                f"(needed by {', '.join(requirement.targets)})")

    if problems:
        print("\nfetch-profiles: these profiles cannot sign this commit:", file=sys.stderr)
        for problem in problems:
            print(f"  ✗ {problem}", file=sys.stderr)
        print("\nThe portal is behind project.yml. Run\n"
              "    Scripts/sync-signing-assets.py\n"
              "to enable the missing App ID capabilities and reissue the profiles.",
              file=sys.stderr)
        return 1

    print("  ✓ every profile carries the entitlements this commit signs with")
    return 0


if __name__ == "__main__":
    sys.exit(main())
