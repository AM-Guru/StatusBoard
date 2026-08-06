#!/usr/bin/env python3
"""Install the App Store provisioning profiles this project signs with.

Release builds sign manually, so the profiles have to be on disk before
xcodebuild runs. Fetching them from App Store Connect at build time — rather
than carrying each one as a base64 secret — means a renewed profile is picked
up automatically and there is nothing extra to rotate.

    ASC_KEY_ID=... ASC_ISSUER_ID=... ASC_PRIVATE_KEY_PATH=... Scripts/fetch-profiles.py

Standard library only: the build machine has no third-party Python, so the
ES256 JWT is signed by shelling out to openssl and converting the DER
signature to the raw r||s form JWT requires.
"""
import base64, json, os, subprocess, sys, tempfile, time, urllib.request

PREFIX = "Status Board "          # only this project's profiles
DEST = os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles")


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def der_to_raw(der: bytes, size: int = 32) -> bytes:
    """ECDSA DER SEQUENCE{INTEGER r, INTEGER s} -> fixed-width r||s."""
    if der[0] != 0x30:
        raise ValueError("not a DER sequence")
    idx = 2 if der[1] < 0x80 else 3 + (der[1] & 0x7F) - 1
    out = b""
    for _ in range(2):
        if der[idx] != 0x02:
            raise ValueError("expected INTEGER")
        length = der[idx + 1]
        value = der[idx + 2: idx + 2 + length].lstrip(b"\x00")
        out += value.rjust(size, b"\x00")
        idx += 2 + length
    return out


def token(key_id: str, issuer: str, key_path: str) -> str:
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    payload = b64url(json.dumps({
        "iss": issuer, "exp": int(time.time()) + 600, "aud": "appstoreconnect-v1"}).encode())
    signing_input = f"{header}.{payload}".encode()
    with tempfile.NamedTemporaryFile() as f:
        f.write(signing_input)
        f.flush()
        der = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", key_path, f.name],
            capture_output=True, check=True).stdout
    return f"{header}.{payload}.{b64url(der_to_raw(der))}"


def main() -> int:
    key_id = os.environ.get("ASC_KEY_ID")
    issuer = os.environ.get("ASC_ISSUER_ID")
    key_path = os.environ.get("ASC_PRIVATE_KEY_PATH") or os.path.expanduser(
        f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8")
    if not (key_id and issuer and os.path.exists(key_path)):
        print("fetch-profiles: ASC_KEY_ID / ASC_ISSUER_ID / key file required", file=sys.stderr)
        return 1

    request = urllib.request.Request(
        "https://api.appstoreconnect.apple.com/v1/profiles?limit=200")
    request.add_header("Authorization", "Bearer " + token(key_id, issuer, key_path))
    with urllib.request.urlopen(request) as response:
        profiles = json.load(response)["data"]

    os.makedirs(DEST, exist_ok=True)
    installed = 0
    for profile in profiles:
        attrs = profile["attributes"]
        if not attrs["name"].startswith(PREFIX):
            continue
        if attrs.get("profileState") != "ACTIVE":
            print(f"  ! skipping {attrs['name']} ({attrs.get('profileState')})")
            continue
        path = os.path.join(DEST, f"{attrs['uuid']}.mobileprovision")
        with open(path, "wb") as out:
            out.write(base64.b64decode(attrs["profileContent"]))
        print(f"  ✓ {attrs['name']}  ({attrs['profileType']})")
        installed += 1

    if not installed:
        print(f"fetch-profiles: no ACTIVE profiles named '{PREFIX}*'", file=sys.stderr)
        return 1
    print(f"  installed {installed} profile(s) into {DEST}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
