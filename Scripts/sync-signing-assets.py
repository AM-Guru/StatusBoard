#!/usr/bin/env python3
"""Make the developer portal match what project.yml asks to be signed.

Release builds sign manually against named App Store profiles, and a profile is a
frozen snapshot of its App ID: it carries the capabilities that were enabled the
moment it was issued and never learns about later ones. So an entitlement added in
a commit is only half a change — without the matching portal edit the archive dies
with

    Provisioning profile "Status Board iOS App Store" doesn't include the
    com.apple.developer.homekit entitlement.

which is exactly how the HomeKit release failed. Doing that edit by hand means
remembering it, on the day, for every new entitlement. This does it instead:

  1. enable any capability project.yml needs that the App ID is missing;
  2. reissue every profile that does not carry all of its target's entitlements
     — including the ones step 1 has just invalidated;
  3. re-read the result and refuse to continue if anything is still short.

Idempotent, so every release runs it and a release that changes nothing prints
nothing but ✓. Nothing is ever removed from the portal: a capability this project
no longer uses is reported, not disabled, because other apps may share the App ID.

    Scripts/sync-signing-assets.py           reconcile
    Scripts/sync-signing-assets.py --check   report drift, change nothing (exit 1)

Standard library only — the build machine has no third-party Python.
"""
import base64
import datetime
import sys

import asc_api
import signing_spec

# An Apple Distribution certificate signs App Store builds on every platform,
# macOS included; the separate Mac Installer certificate signs the .pkg and never
# appears in a profile.
DISTRIBUTION_CERTIFICATE_TYPES = {"DISTRIBUTION"}


def bundle_ids():
    """identifier -> App Store Connect id, for every App ID in the team."""
    return {item["attributes"]["identifier"]: item["id"]
            for item in asc_api.get("/v1/bundleIds?limit=200")["data"]}


def enabled_capabilities(bundle_id):
    # No `limit` here: this relationship rejects it outright.
    body = asc_api.get(f"/v1/bundleIds/{bundle_id}/bundleIdCapabilities")
    return {item["attributes"]["capabilityType"] for item in body["data"]}


def enable_capability(bundle_id, capability):
    # No `settings` key at all rather than an empty list: a capability that wants
    # settings rejects the empty list outright, and one that does not never reads it.
    status, body = asc_api.call("POST", "/v1/bundleIdCapabilities", {
        "data": {
            "type": "bundleIdCapabilities",
            "attributes": {"capabilityType": capability},
            "relationships": {"bundleId": asc_api.rel("bundleIds", bundle_id)},
        }})
    if status >= 300:
        raise SystemExit(
            f"Could not enable {capability} on {bundle_id}: {status} {body}\n\n"
            "Some capabilities need extra configuration and cannot be turned on\n"
            "blind (iCloud wants its containers, App Groups its group). Enable it\n"
            "once at https://developer.apple.com/account/resources/identifiers\n"
            "and re-run — everything after this point is automatic.")


def distribution_certificates():
    now = datetime.datetime.now(datetime.timezone.utc)
    ids = []
    for item in asc_api.get("/v1/certificates?limit=200")["data"]:
        attrs = item["attributes"]
        if attrs["certificateType"] not in DISTRIBUTION_CERTIFICATE_TYPES:
            continue
        # "2027-07-19T12:34:56.000+0000" — %z wants no colon, which is how
        # App Store Connect writes it, but be lenient about a trailing Z.
        expires = attrs.get("expirationDate", "").replace("Z", "+0000")
        if expires and datetime.datetime.strptime(
                expires, "%Y-%m-%dT%H:%M:%S.%f%z") <= now:
            continue
        ids.append(item["id"])
    if not ids:
        raise SystemExit(
            "No Apple Distribution certificate in this team, so no App Store profile\n"
            "can be issued. Create one at\n"
            "https://developer.apple.com/account/resources/certificates")
    return ids


def profiles_by_name():
    body = asc_api.get("/v1/profiles?limit=200&include=certificates")
    found = {}
    for item in body["data"]:
        found.setdefault(item["attributes"]["name"], []).append(item)
    return found


def certificates_of(profile):
    return [rel["id"] for rel in (profile["relationships"]["certificates"]["data"] or [])]


def create_profile(requirement, bundle_id, certificate_ids):
    return asc_api.call("POST", "/v1/profiles", {
        "data": {
            "type": "profiles",
            "attributes": {"name": requirement.name,
                           "profileType": requirement.profile_type},
            "relationships": {
                "bundleId": asc_api.rel("bundleIds", bundle_id),
                "certificates": {"data": [{"type": "certificates", "id": identifier}
                                          for identifier in certificate_ids]},
            },
        }})


def reissue(requirement, bundle_id, superseded, certificate_ids):
    """Replace `superseded` with a freshly issued profile of the same name.

    Created before the old one is deleted where Apple allows it, so a failure
    leaves the project with the stale profile rather than with none at all. Apple
    does reject a duplicate name on some profile types, and then there is no
    choice but to delete first.
    """
    status, body = create_profile(requirement, bundle_id, certificate_ids)
    if status >= 300:
        if not superseded:
            raise SystemExit(f"Could not create profile {requirement.name!r}: "
                             f"{status} {body}")
        for profile in superseded:
            asc_api.call("DELETE", f"/v1/profiles/{profile['id']}")
        status, body = create_profile(requirement, bundle_id, certificate_ids)
        if status >= 300:
            raise SystemExit(
                f"Could not reissue profile {requirement.name!r} after deleting the\n"
                f"old one: {status} {body}\n\n"
                "The project cannot sign without it. Recreate it at\n"
                "https://developer.apple.com/account/resources/profiles with type\n"
                f"{requirement.profile_type} for {requirement.bundle_id}.")
        return body["data"]

    for profile in superseded:
        asc_api.call("DELETE", f"/v1/profiles/{profile['id']}")
    return body["data"]


def shortfall(requirement, profile):
    """Why this profile will not do, or None when it will."""
    state = profile["attributes"].get("profileState")
    if state != "ACTIVE":
        return f"state {state}"
    content = base64.b64decode(profile["attributes"]["profileContent"])
    missing = signing_spec.missing_entitlements(requirement, content)
    if missing:
        return "missing " + ", ".join(missing)
    return None


def main(argv):
    check_only = "--check" in argv[1:]
    unknown = [arg for arg in argv[1:] if arg != "--check"]
    if unknown:
        raise SystemExit(f"unknown option: {unknown[0]}")

    requirements = signing_spec.load()
    identifiers = bundle_ids()
    wanted = signing_spec.capabilities_by_bundle_id(requirements)

    drift = []
    changed_bundle_ids = set()

    for identifier, capabilities in sorted(wanted.items()):
        if identifier not in identifiers:
            raise SystemExit(
                f"No App ID {identifier!r} in this team. Register it at\n"
                "https://developer.apple.com/account/resources/identifiers first —\n"
                "project.yml signs a target with it.")
        bundle_id = identifiers[identifier]
        missing = sorted(capabilities - enabled_capabilities(bundle_id))
        if not missing:
            continue
        drift.append(f"{identifier} needs capability {', '.join(missing)}")
        if check_only:
            continue
        for capability in missing:
            enable_capability(bundle_id, capability)
            print(f"  + {identifier}: enabled {capability}")
        changed_bundle_ids.add(identifier)

    # Enabling a capability invalidates every profile already issued for that App
    # ID, so this pass has to run after — and read the portal fresh, not the copy
    # taken before the capabilities changed.
    existing = profiles_by_name()
    certificates = None
    for name, requirement in sorted(requirements.items()):
        candidates = existing.get(name, [])
        if not candidates:
            reason = "does not exist"
        elif requirement.bundle_id in changed_bundle_ids:
            reason = "invalidated by the capability change above"
        else:
            reason = None
            for profile in candidates:
                reason = shortfall(requirement, profile)
                if reason is None:
                    break
        if reason is None:
            continue

        drift.append(f"profile {name!r} {reason}")
        if check_only:
            continue
        if certificates is None:
            certificates = distribution_certificates()
        # Keep whatever certificate the old profile was issued against, but only
        # while that certificate is still a valid distribution one — a profile
        # being reissued because it went stale may well be carrying a certificate
        # that has since been revoked or replaced, and naming it would fail.
        signers = [identifier for identifier in (certificates_of(candidates[0])
                                                 if candidates else [])
                   if identifier in certificates]
        reissue(requirement, identifiers[requirement.bundle_id], candidates,
                signers or certificates)
        print(f"  + reissued {name} ({reason})")

    if check_only:
        if drift:
            print("Signing assets are out of date:")
            for item in drift:
                print(f"  ✗ {item}")
            print("\nRun Scripts/sync-signing-assets.py to bring them up to date.")
            return 1
        print("  ✓ portal capabilities and profiles match project.yml")
        return 0

    # Believe the portal, not the calls that were just made. A profile can come
    # back ACTIVE and still be short of an entitlement if a capability silently
    # refused to apply, and finding that out here beats finding it out from
    # xcodebuild fifteen minutes into an archive.
    final = profiles_by_name()
    problems = []
    for name, requirement in sorted(requirements.items()):
        candidates = final.get(name, [])
        if not candidates:
            problems.append(f"{name}: still missing from App Store Connect")
            continue
        reasons = [shortfall(requirement, profile) for profile in candidates]
        if all(reasons):
            problems.append(f"{name}: {reasons[0]}")
    if problems:
        print("Signing assets are still not usable:", file=sys.stderr)
        for problem in problems:
            print(f"  ✗ {problem}", file=sys.stderr)
        return 1

    if drift:
        print(f"  ✓ {len(drift)} signing change(s) applied and verified")
    else:
        print("  ✓ portal capabilities and profiles match project.yml")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
