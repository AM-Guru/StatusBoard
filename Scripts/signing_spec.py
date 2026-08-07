"""What a Status Board release needs from the developer portal, read from project.yml.

Every Release configuration signs manually against a named App Store profile, and
a profile only carries the entitlements that were enabled on its App ID when it
was issued. So adding an entitlement to project.yml is a *portal* change as much
as a source change: enable the capability on the bundle id, reissue the profile.
Skip it and the archive dies with

    Provisioning profile "Status Board iOS App Store" doesn't include the
    com.apple.developer.homekit entitlement.

This module is the single description of what the portal has to look like. It is
derived from `xcodegen dump` rather than hand-maintained, so it cannot drift from
the project: add an entitlement to project.yml and the requirement appears here.

Standard library only — the build machine has no third-party Python, PyYAML
included, which is why the spec comes through XcodeGen's own JSON dump.
"""
import json
import os
import plistlib
import subprocess
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The profile an App Store build of each platform needs. watchOS has no App Store
# profile type of its own — the watch app ships inside the iOS archive and signs
# with an IOS_APP_STORE profile.
PROFILE_TYPES = {
    "iOS": "IOS_APP_STORE",
    "watchOS": "IOS_APP_STORE",
    "tvOS": "TVOS_APP_STORE",
    "macOS": "MAC_APP_STORE",
}

# Entitlement key -> the App Store Connect capabilityType that has to be enabled
# on the App ID before a profile can carry it. Only the entitlements that are
# gated this way appear here; see NO_CAPABILITY for the ones that are not.
CAPABILITY_FOR_ENTITLEMENT = {
    "aps-environment": "PUSH_NOTIFICATIONS",
    "com.apple.developer.applesignin": "APPLE_ID_AUTH",
    "com.apple.developer.associated-domains": "ASSOCIATED_DOMAINS",
    "com.apple.developer.default-data-protection": "DATA_PROTECTION",
    "com.apple.developer.family-controls": "FAMILY_CONTROLS",
    "com.apple.developer.game-center": "GAME_CENTER",
    "com.apple.developer.healthkit": "HEALTHKIT",
    "com.apple.developer.homekit": "HOMEKIT",
    "com.apple.developer.icloud-container-identifiers": "ICLOUD",
    "com.apple.developer.icloud-services": "ICLOUD",
    "com.apple.developer.in-app-payments": "APPLE_PAY",
    "com.apple.developer.kernel.increased-memory-limit": "INCREASED_MEMORY_LIMIT",
    "com.apple.developer.maps": "MAPS",
    "com.apple.developer.networking.multicast": "MULTICAST",
    "com.apple.developer.networking.networkextension": "NETWORK_EXTENSIONS",
    "com.apple.developer.networking.vpn.api": "PERSONAL_VPN",
    "com.apple.developer.networking.wifi-info": "ACCESS_WIFI_INFORMATION",
    "com.apple.developer.nfc.readersession.formats": "NFC_TAG_READING",
    "com.apple.developer.pass-type-identifiers": "WALLET",
    "com.apple.developer.push-to-talk": "PUSH_TO_TALK",
    "com.apple.developer.siri": "SIRIKIT",
    "com.apple.developer.ubiquity-kvstore-identifier": "ICLOUD",
    "com.apple.developer.usernotifications.communication": "COMMUNICATION_NOTIFICATIONS",
    "com.apple.developer.usernotifications.time-sensitive": "TIME_SENSITIVE_NOTIFICATIONS",
    "com.apple.developer.weatherkit": "WEATHERKIT",
    "com.apple.external-accessory.wireless-configuration": "WIRELESS_ACCESSORY_CONFIGURATION",
    "com.apple.security.application-groups": "APP_GROUPS",
}

# Entitlements that need no portal capability, so a build never fails for want of
# one. Everything under `com.apple.security.` is a macOS App Sandbox switch and is
# handled by the prefix rule in `capabilities_for`; `com.apple.security.application-groups`
# is the one exception and is in the table above.
NO_CAPABILITY = {
    "application-identifier",
    "com.apple.developer.team-identifier",
    "keychain-access-groups",
}


class UnknownEntitlement(Exception):
    """An entitlement no one has classified yet.

    Deliberately fatal rather than assumed harmless: guessing wrong the safe-looking
    way is how HomeKit reached CI without its capability and burned a release.
    """


class Requirement:
    """One named profile: which App ID it is for, and what it must carry."""

    def __init__(self, name, profile_type, bundle_id):
        self.name = name
        self.profile_type = profile_type
        self.bundle_id = bundle_id
        self.entitlements = {}
        self.targets = []

    def __repr__(self):
        return f"<Requirement {self.name} {self.profile_type} {self.bundle_id}>"

    @property
    def capabilities(self):
        return capabilities_for(self.entitlements)


def capabilities_for(entitlements):
    """The capabilityTypes these entitlement keys require. Raises on an unknown key."""
    required, unknown = set(), []
    for key in entitlements:
        if key in CAPABILITY_FOR_ENTITLEMENT:
            required.add(CAPABILITY_FOR_ENTITLEMENT[key])
        elif key in NO_CAPABILITY:
            continue
        elif key.startswith("com.apple.security."):
            continue          # App Sandbox switch, not a portal capability
        else:
            unknown.append(key)
    if unknown:
        raise UnknownEntitlement(
            "project.yml uses entitlement(s) this project has never classified:\n"
            + "".join(f"    {key}\n" for key in sorted(unknown))
            + "\nAdd each one to CAPABILITY_FOR_ENTITLEMENT in Scripts/signing_spec.py\n"
            "(with the App Store Connect capabilityType it needs on the App ID) or to\n"
            "NO_CAPABILITY (when it needs nothing there). Apple's list of types is at\n"
            "https://developer.apple.com/documentation/appstoreconnectapi/capabilitytype")
    return required


def load(repo_root=REPO_ROOT):
    """Every profile this project signs Release builds with, keyed by profile name."""
    # Not `--quiet`: that silences the dump itself, not just the chatter.
    dump = subprocess.run(["xcodegen", "dump", "--type", "json"],
                          cwd=repo_root, capture_output=True, text=True, check=True)
    spec = json.loads(dump.stdout)

    requirements = {}
    for target_name, target in sorted(spec.get("targets", {}).items()):
        settings = target.get("settings", {})
        release = settings.get("configs", {}).get("Release", {})
        profile_name = release.get("PROVISIONING_PROFILE_SPECIFIER")
        if not profile_name:
            continue          # not a manually signed target
        platform = target.get("platform")
        if platform not in PROFILE_TYPES:
            raise SystemExit(f"{target_name}: unknown platform {platform!r}")
        bundle_id = settings.get("base", {}).get("PRODUCT_BUNDLE_IDENTIFIER")
        if not bundle_id:
            raise SystemExit(f"{target_name}: no PRODUCT_BUNDLE_IDENTIFIER")

        requirement = requirements.get(profile_name)
        if requirement is None:
            requirement = requirements[profile_name] = Requirement(
                profile_name, PROFILE_TYPES[platform], bundle_id)
        elif (requirement.bundle_id, requirement.profile_type) != (
                bundle_id, PROFILE_TYPES[platform]):
            raise SystemExit(
                f"Profile {profile_name!r} is claimed by two different identities: "
                f"{requirement.bundle_id}/{requirement.profile_type} and "
                f"{bundle_id}/{PROFILE_TYPES[platform]}")
        requirement.targets.append(target_name)
        requirement.entitlements.update(target.get("entitlements", {}).get("properties", {}))

    if not requirements:
        raise SystemExit("No manually signed Release targets found in project.yml.")
    return requirements


def capabilities_by_bundle_id(requirements):
    """capabilityTypes each App ID needs, unioned over every profile that uses it.

    One App ID serves several platforms — guru.am.StatusBoard is the iOS, tvOS and
    macOS app — so a capability only one of them asks for still has to be enabled.
    """
    wanted = {}
    for requirement in requirements.values():
        wanted.setdefault(requirement.bundle_id, set()).update(requirement.capabilities)
    return wanted


def profile_entitlements(content):
    """The Entitlements dict inside a .mobileprovision (raw CMS bytes)."""
    with tempfile.NamedTemporaryFile(suffix=".mobileprovision") as handle:
        handle.write(content)
        handle.flush()
        decoded = subprocess.run(["security", "cms", "-D", "-i", handle.name],
                                 capture_output=True, check=True).stdout
    return plistlib.loads(decoded).get("Entitlements", {})


def missing_entitlements(requirement, content):
    """Which portal-granted entitlement keys this profile does not carry.

    Only the keys that come from an App ID capability are looked for. The App
    Sandbox switches a Mac target sets — `com.apple.security.app-sandbox` and its
    neighbours — are applied at signing time and never appear in a profile, so
    expecting them there would condemn every Mac profile ever issued.

    Presence only, not values: a profile legitimately widens some keys (a wildcard
    application-identifier, a superset of iCloud containers), and it is the missing
    *key* that xcodebuild refuses to sign against.
    """
    carried = profile_entitlements(content)
    return sorted(key for key in requirement.entitlements
                  if key in CAPABILITY_FOR_ENTITLEMENT and key not in carried)


def _main():
    """Print what this commit needs signed. Offline — no App Store Connect key.

    Run from Scripts/validate-release-configuration.sh, where it is the cheapest
    possible place to catch an entitlement nobody has classified: no credentials,
    no network, seconds rather than a quarter of an hour into an archive.
    """
    import sys
    try:
        requirements = load()
    except UnknownEntitlement as error:
        print(f"  ✗ {error}", file=sys.stderr)
        return 1
    for name, requirement in sorted(requirements.items()):
        capabilities = ", ".join(sorted(requirement.capabilities)) or "none"
        print(f"  · {name} ({requirement.bundle_id}): {capabilities}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
