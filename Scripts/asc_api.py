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


def credentials():
    key_id = os.environ.get("ASC_KEY_ID")
    issuer = os.environ.get("ASC_ISSUER_ID")
    key_path = os.environ.get("ASC_PRIVATE_KEY_PATH") or os.path.expanduser(
        f"~/.appstoreconnect/private_keys/AuthKey_{key_id}.p8")
    if not (key_id and issuer and os.path.exists(key_path)):
        raise SystemExit("ASC_KEY_ID, ASC_ISSUER_ID and the .p8 key are required")
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
