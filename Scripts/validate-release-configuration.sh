#!/usr/bin/env bash
#
# Fails fast, and with a readable reason, when a release runner is not set up
# correctly — before anything spends fifteen minutes archiving.
#
#     Scripts/validate-release-configuration.sh
#
# Checks the host has the tools it needs and that every required secret and
# variable is present. It never prints a secret value, only whether it is set.

set -euo pipefail

failures=0

fail() { echo "  ✗ $1" >&2; failures=$((failures + 1)); }
pass() { echo "  ✓ $1"; }

echo "▸ Host"

if [[ "$(uname -s)" != "Darwin" ]]; then
  fail "not macOS (uname -s = $(uname -s))"
else
  pass "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
fi

developer_dir="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
if [[ -z "${developer_dir}" || ! -x "${developer_dir}/usr/bin/xcodebuild" ]]; then
  fail "no usable Xcode at '${developer_dir:-unset}'"
else
  pass "Xcode $("${developer_dir}/usr/bin/xcodebuild" -version | head -1 | awk '{print $2}') at ${developer_dir}"
fi

for tool in security codesign xcrun openssl plutil; do
  command -v "$tool" >/dev/null || fail "missing tool: ${tool}"
done

if command -v xcodegen >/dev/null; then
  pass "xcodegen $(xcodegen --version 2>/dev/null | tail -1)"
elif command -v brew >/dev/null; then
  pass "xcodegen absent, but brew is available to install it"
else
  fail "neither xcodegen nor brew is on PATH (a launchd service does not inherit /opt/homebrew/bin — set it in the runner's .env)"
fi

echo "▸ Configuration"

for name in APPLE_TEAM_ID APP_STORE_DISTRIBUTION; do
  if [[ -z "${!name:-}" ]]; then
    fail "variable ${name} is not set"
  else
    pass "${name} = ${!name}"
  fi
done

if [[ -n "${APPLE_TEAM_ID:-}" && -n "${APP_STORE_DISTRIBUTION:-}" ]]; then
  if [[ "${APP_STORE_DISTRIBUTION}" != Apple\ Distribution:*"(${APPLE_TEAM_ID})" ]]; then
    fail "APP_STORE_DISTRIBUTION does not end with (${APPLE_TEAM_ID})"
  fi
fi

echo "▸ Secrets (presence only)"

for name in ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY \
            APP_STORE_DISTRIBUTION_P12_BASE64 APP_STORE_DISTRIBUTION_P12_PASSWORD \
            TVOS_PROVISIONING_PROFILE_BASE64; do
  if [[ -z "${!name:-}" ]]; then
    fail "secret ${name} is empty or not passed to this step"
  else
    pass "${name} is set"
  fi
done

# Cheap shape checks that catch the usual copy-paste damage.
if [[ -n "${ASC_KEY_ID:-}" && ${#ASC_KEY_ID} -ne 10 ]]; then
  fail "ASC_KEY_ID should be 10 characters, got ${#ASC_KEY_ID}"
fi
if [[ -n "${ASC_ISSUER_ID:-}" && ${#ASC_ISSUER_ID} -ne 36 ]]; then
  fail "ASC_ISSUER_ID should be a 36-character UUID, got ${#ASC_ISSUER_ID}"
fi
if [[ -n "${ASC_PRIVATE_KEY:-}" ]] && ! grep -q "BEGIN PRIVATE KEY" <<<"${ASC_PRIVATE_KEY}"; then
  fail "ASC_PRIVATE_KEY has no 'BEGIN PRIVATE KEY' line — it may have been truncated"
fi

if ((failures)); then
  echo
  echo "${failures} problem(s) found." >&2
  exit 1
fi
echo
echo "All release configuration checks passed."
