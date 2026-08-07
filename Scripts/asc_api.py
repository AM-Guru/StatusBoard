"""Minimal App Store Connect client shared by the release scripts.

Standard library only — the build machine has no third-party Python — so the
ES256 JWT is signed by shelling out to openssl and converting the DER
signature into the raw r||s form JWT requires.
"""
import base64, json, os, subprocess, tempfile, time, urllib.error, urllib.request

BASE = "https://api.appstoreconnect.apple.com"
APP_ID = os.environ.get("ASC_APP_ID", "6798804445")


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def _der_to_raw(der: bytes, size: int = 32) -> bytes:
    if der[0] != 0x30:
        raise ValueError("not a DER sequence")
    idx = 2 if der[1] < 0x80 else 3 + (der[1] & 0x7F) - 1
    out = b""
    for _ in range(2):
        if der[idx] != 0x02:
            raise ValueError("expected INTEGER")
        length = der[idx + 1]
        out += der[idx + 2: idx + 2 + length].lstrip(b"\x00").rjust(size, b"\x00")
        idx += 2 + length
    return out


KEYCHAIN_SERVICE = os.environ.get("ASC_KEYCHAIN_SERVICE",
                                  "Status Board: App Store Connect")
KEY_DIR = os.path.expanduser(
    os.environ.get("ASC_KEY_DIR", "~/.appstoreconnect/private_keys"))
ISSUING_PAGE = "https://appstoreconnect.apple.com/access/integrations/api"

MISSING = f"""App Store Connect credentials not found.

Looked in the environment (ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY_PATH),
the login keychain (service "{KEYCHAIN_SERVICE}") and {KEY_DIR}.

Issue or look up a key at App Store Connect — Users and Access > Integrations >
App Store Connect API:

    {ISSUING_PAGE}

The issuer id is at the top of that page and the key id beside each key. The
.p8 downloads only when the key is created and cannot be recovered afterwards.

Store them once with:

    Scripts/asc-credentials.sh save --key-id … --issuer-id … --private-key …
"""


def _keychain(account):
    """Reads one generic-password item, or None when it is not there."""
    try:
        result = subprocess.run(
            ["security", "find-generic-password",
             "-s", KEYCHAIN_SERVICE, "-a", account, "-w"],
            capture_output=True, text=True)
    except OSError:
        return None
    return result.stdout.strip() or None if result.returncode == 0 else None


def credentials():
    key_id = os.environ.get("ASC_KEY_ID") or _keychain("key-id")
    issuer = os.environ.get("ASC_ISSUER_ID") or _keychain("issuer-id")
    if not (key_id and issuer):
        raise SystemExit(MISSING)

    key_path = os.environ.get("ASC_PRIVATE_KEY_PATH")
    key_path = os.path.expanduser(key_path) if key_path else None
    if not (key_path and os.path.exists(key_path)):
        key_path = os.path.join(KEY_DIR, f"AuthKey_{key_id}.p8")
    # The key can live only in the keychain — Scripts/asc-credentials.sh save
    # puts it there so the downloaded copy can be deleted. openssl needs a
    # file, so write it back out where xcodebuild also expects to find it.
    if not os.path.exists(key_path):
        # Stored base64: `security find-generic-password -w` hex-dumps any
        # value containing a newline, and a PEM is nothing but newlines.
        encoded = _keychain("private-key")
        if not encoded:
            raise SystemExit(MISSING)
        os.makedirs(KEY_DIR, exist_ok=True)
        key_path = os.path.join(KEY_DIR, f"AuthKey_{key_id}.p8")
        with open(os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600),
                  "wb") as handle:
            handle.write(base64.b64decode(encoded))
    return key_id, issuer, key_path


_cached = {"token": None, "exp": 0}


def token() -> str:
    if _cached["token"] and time.time() < _cached["exp"] - 60:
        return _cached["token"]
    key_id, issuer, key_path = credentials()
    exp = int(time.time()) + 600
    header = _b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    payload = _b64url(json.dumps(
        {"iss": issuer, "exp": exp, "aud": "appstoreconnect-v1"}).encode())
    with tempfile.NamedTemporaryFile() as f:
        f.write(f"{header}.{payload}".encode())
        f.flush()
        der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path, f.name],
                             capture_output=True, check=True).stdout
    _cached.update(token=f"{header}.{payload}.{_b64url(_der_to_raw(der))}", exp=exp)
    return _cached["token"]


def call(method: str, path: str, body=None):
    """Returns (status, parsed-json-or-text)."""
    url = path if path.startswith("http") else BASE + path
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", "Bearer " + token())
    if data:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request) as response:
            text = response.read().decode()
            return response.status, (json.loads(text) if text else {})
    except urllib.error.HTTPError as error:
        text = error.read().decode()
        try:
            return error.code, json.loads(text)
        except ValueError:
            return error.code, text


def get(path):
    status, body = call("GET", path)
    if status >= 300:
        raise SystemExit(f"GET {path} -> {status}: {body}")
    return body


def rel(kind, ident):
    return {"data": {"type": kind, "id": ident}}
