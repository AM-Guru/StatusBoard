#!/usr/bin/env bash
#
# Finds the App Store Connect API credentials, or explains exactly how to get
# them. Sourced by Scripts/release.sh; also runnable on its own:
#
#     Scripts/asc-credentials.sh show     # where each value came from
#     Scripts/asc-credentials.sh save …   # remember them in the login keychain
#     Scripts/asc-credentials.sh where    # the page that issues them
#
# Three values are needed, and they are not interchangeable:
#
#   ASC_KEY_ID     10 characters, e.g. ABC1234567
#   ASC_ISSUER_ID  a 36-character UUID, one per team
#   AuthKey_<ID>.p8  the ES256 private key that signs every request
#
# Resolution order, first hit wins per value:
#
#   1. the environment
#   2. $ASC_ENV_FILE (default ~/Repo/appstoreconnect/.env)
#   3. the login keychain, service "Status Board: App Store Connect"
#   4. ~/.appstoreconnect/private_keys (key material only)
#
# The keychain is the one that survives a new checkout without leaving the
# issuer id in a dotfile, so `save` puts everything there once and no later run
# needs an argument.
#
# There is deliberately no "scrape it out of the web UI" path. The .p8 is
# downloadable exactly once, at the moment the key is created — App Store
# Connect never shows it again, so no amount of signing in recovers it. The key
# id and issuer id *are* on that page, which is why `where` points at it.

ASC_KEYCHAIN_SERVICE="${ASC_KEYCHAIN_SERVICE:-Status Board: App Store Connect}"
ASC_KEY_DIR="${ASC_KEY_DIR:-$HOME/.appstoreconnect/private_keys}"
ASC_ISSUING_PAGE="https://appstoreconnect.apple.com/access/integrations/api"

# Where each value ended up coming from, for `show` and for release.sh's log.
ASC_KEY_ID_ORIGIN=""
ASC_ISSUER_ID_ORIGIN=""
ASC_PRIVATE_KEY_ORIGIN=""

_asc_keychain_read() {          # _asc_keychain_read <account>
  security find-generic-password -s "$ASC_KEYCHAIN_SERVICE" -a "$1" -w 2>/dev/null
}

_asc_expand() { echo "${1/#\~/$HOME}"; }

# ── The .env, parsed rather than sourced ─────────────────────────────────────
# One of its values contains an unquoted space, which `source` would try to
# execute. Only the keys below are read, and only when not already set.
_asc_read_env_file() {
  local file="${ASC_ENV_FILE:-$HOME/Repo/appstoreconnect/.env}" key value
  [[ -f "$file" ]] || return 0
  while IFS='=' read -r key value; do
    key="${key#"${key%%[![:space:]]*}"}"
    [[ "$key" =~ ^(ASC_KEY_ID|ASC_ISSUER_ID|ASC_PRIVATE_KEY_PATH|DEVELOPMENT_TEAM)$ ]] || continue
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
    [[ -z "${!key:-}" ]] || continue
    export "$key=$value"
    case "$key" in
      ASC_KEY_ID) ASC_KEY_ID_ORIGIN="$file" ;;
      ASC_ISSUER_ID) ASC_ISSUER_ID_ORIGIN="$file" ;;
    esac
  done < "$file"
}

# ── Resolution ───────────────────────────────────────────────────────────────
# Exports ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY_PATH. Returns 1 with
# nothing printed when something is missing; the caller decides whether to
# print asc_credentials_help and exit.
asc_resolve_credentials() {
  [[ -n "${ASC_KEY_ID:-}" ]] && ASC_KEY_ID_ORIGIN="environment"
  [[ -n "${ASC_ISSUER_ID:-}" ]] && ASC_ISSUER_ID_ORIGIN="environment"

  _asc_read_env_file

  if [[ -z "${ASC_KEY_ID:-}" ]]; then
    ASC_KEY_ID="$(_asc_keychain_read key-id)" || true
    [[ -n "$ASC_KEY_ID" ]] && ASC_KEY_ID_ORIGIN="login keychain" || unset ASC_KEY_ID
  fi
  if [[ -z "${ASC_ISSUER_ID:-}" ]]; then
    ASC_ISSUER_ID="$(_asc_keychain_read issuer-id)" || true
    [[ -n "$ASC_ISSUER_ID" ]] && ASC_ISSUER_ID_ORIGIN="login keychain" || unset ASC_ISSUER_ID
  fi
  [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]] || return 1
  export ASC_KEY_ID ASC_ISSUER_ID

  # xcodebuild only authenticates when the key sits in the well-known directory
  # and is referenced by id — -authenticationKeyPath fails with "Authentication
  # failed: Make sure a bearer token was provided". So wherever it is found, it
  # ends up copied there.
  local name="AuthKey_${ASC_KEY_ID}.p8" found="" dir
  for dir in "$ASC_KEY_DIR" "$HOME/private_keys" "$HOME/Repo/appstoreconnect/private_keys"; do
    if [[ -f "$dir/$name" ]]; then
      found="$dir/$name"; ASC_PRIVATE_KEY_ORIGIN="$dir"; break
    fi
  done
  if [[ -z "$found" && -n "${ASC_PRIVATE_KEY_PATH:-}" ]]; then
    local given; given="$(_asc_expand "$ASC_PRIVATE_KEY_PATH")"
    [[ -f "$given" ]] && found="$given" && ASC_PRIVATE_KEY_ORIGIN="ASC_PRIVATE_KEY_PATH"
  fi
  # Last resort: the key was saved into the keychain, so materialise it.
  # Stored base64 — `security find-generic-password -w` dumps anything
  # containing a newline as a hex string, which a PEM always does.
  if [[ -z "$found" ]]; then
    local encoded; encoded="$(_asc_keychain_read private-key)" || true
    if [[ -n "$encoded" ]]; then
      mkdir -p "$ASC_KEY_DIR"
      ( umask 077; printf '%s' "$encoded" | /usr/bin/base64 -D > "$ASC_KEY_DIR/$name" )
      found="$ASC_KEY_DIR/$name"
      ASC_PRIVATE_KEY_ORIGIN="login keychain"
    fi
  fi
  [[ -n "$found" ]] || return 1

  if [[ "$found" != "$ASC_KEY_DIR/$name" ]]; then
    mkdir -p "$ASC_KEY_DIR"
    cp "$found" "$ASC_KEY_DIR/$name"
    chmod 600 "$ASC_KEY_DIR/$name"
  fi
  export ASC_PRIVATE_KEY_PATH="$ASC_KEY_DIR/$name"
}

asc_credentials_help() {
  cat >&2 <<HELP
App Store Connect credentials not found.

Looked in, in order:
  · the environment       ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY_PATH
  · ${ASC_ENV_FILE:-$HOME/Repo/appstoreconnect/.env}
  · the login keychain    service "${ASC_KEYCHAIN_SERVICE}"
  · ${ASC_KEY_DIR}/AuthKey_<KEY_ID>.p8

Get them from App Store Connect — Users and Access ▸ Integrations ▸
App Store Connect API (Team Keys):

    ${ASC_ISSUING_PAGE}

  Issuer ID  is printed once at the top of that page; it is the same for
             every key on the team.
  Key ID     is the column beside each key in the list.
  The .p8    is offered for download only at the moment you create the key.
             Apple will not show it again and it cannot be recovered by
             signing in — if it is lost, revoke that key and generate a new
             one. Creating a key needs the Account Holder or Admin role.

Then remember them, so nothing needs them passed again:

    Scripts/asc-credentials.sh save \\
      --key-id ABC1234567 \\
      --issuer-id 11111111-2222-3333-4444-555555555555 \\
      --private-key ~/Downloads/AuthKey_ABC1234567.p8

That writes to your login keychain, not to the repository.
HELP
}

# ── CLI ─────────────────────────────────────────────────────────────────────
_asc_add() {                    # _asc_add <account> <value>
  # -U updates in place, so re-running save after a key rotation is fine.
  security add-generic-password -U \
    -s "$ASC_KEYCHAIN_SERVICE" -a "$1" -w "$2" \
    -j "App Store Connect API credential used by Status Board's release scripts" \
    >/dev/null
}

_asc_save() {
  local key_id="" issuer_id="" private_key=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --key-id) key_id="$2"; shift 2 ;;
      --issuer-id) issuer_id="$2"; shift 2 ;;
      --private-key) private_key="$2"; shift 2 ;;
      *) echo "unknown option: $1" >&2; return 2 ;;
    esac
  done
  [[ -n "$key_id" && -n "$issuer_id" && -n "$private_key" ]] || {
    echo "save needs --key-id, --issuer-id and --private-key" >&2
    echo "  values come from $ASC_ISSUING_PAGE" >&2
    return 2
  }
  private_key="$(_asc_expand "$private_key")"
  [[ -f "$private_key" ]] || { echo "No such file: $private_key" >&2; return 1; }
  grep -q "BEGIN PRIVATE KEY" "$private_key" || {
    echo "$private_key does not look like a .p8 — no BEGIN PRIVATE KEY line." >&2
    return 1
  }
  # Shape checks catch the usual copy-paste damage before a fifteen-minute
  # archive dies at upload with a 401 that names neither value.
  [[ ${#key_id} -eq 10 ]] || echo "  warning: key id is ${#key_id} characters, expected 10" >&2
  [[ ${#issuer_id} -eq 36 ]] || echo "  warning: issuer id is ${#issuer_id} characters, expected a 36-character UUID" >&2

  _asc_add key-id "$key_id"
  _asc_add issuer-id "$issuer_id"
  # base64, so the stored value is one line of printable ASCII: `security
  # find-generic-password -w` hex-dumps any value containing a newline, and a
  # PEM is nothing but newlines.
  _asc_add private-key "$(/usr/bin/base64 -i "$private_key" | tr -d '\n')"
  echo "✓ Saved to the login keychain as \"$ASC_KEYCHAIN_SERVICE\"."
  echo "  Key ID $key_id. The .p8 is stored too, so the downloaded copy can go."
}

_asc_show() {
  if asc_resolve_credentials; then
    echo "▸ App Store Connect credentials"
    echo "  key id     ${ASC_KEY_ID}  (${ASC_KEY_ID_ORIGIN:-unknown})"
    # The issuer id is not secret, but printing a full one invites pasting it
    # into a screenshot; the origin is what matters when something is wrong.
    echo "  issuer id  ${ASC_ISSUER_ID:0:8}…  (${ASC_ISSUER_ID_ORIGIN:-unknown})"
    echo "  key file   ${ASC_PRIVATE_KEY_PATH}  (${ASC_PRIVATE_KEY_ORIGIN:-unknown})"
  else
    asc_credentials_help
    return 1
  fi
}

# Only act as a CLI when executed, not when sourced.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  case "${1:-show}" in
    show) shift || true; _asc_show ;;
    save) shift; _asc_save "$@" ;;
    where) echo "$ASC_ISSUING_PAGE" ;;
    help|-h|--help) asc_credentials_help ;;
    *) echo "usage: $(basename "$0") [show|save|where]" >&2; exit 2 ;;
  esac
fi
