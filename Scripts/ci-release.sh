#!/usr/bin/env bash
#
# CI entry point for Status Board releases.
#
# The build machine keeps no signing material of its own. This script stands up
# an ephemeral keychain from a base64 PKCS#12 secret, stages the App Store
# Connect key and the tvOS provisioning profile, hands off to Scripts/release.sh,
# and tears all of it down again on the way out — success or failure.
#
# Required secrets (environment):
#   APP_STORE_DISTRIBUTION_P12_BASE64    base64 of a .p12 holding the
#                                        "Apple Distribution" cert + private key
#   APP_STORE_DISTRIBUTION_P12_PASSWORD  password that .p12 was exported with
#   ASC_KEY_ID, ASC_ISSUER_ID            App Store Connect API key identifiers
#   ASC_PRIVATE_KEY                      the .p8 contents, PEM as-is
#
# Required configuration (repository variables):
#   APPLE_TEAM_ID          10-character team id
#   APP_STORE_DISTRIBUTION full identity name, e.g.
#                          "Apple Distribution: AM Guru, LLC (59A594LZGR)"
#
# Optional:
#   PLATFORMS     ios | macos | tvos | all      (default all)
#   BUILD_NUMBER  CFBundleVersion               (default YYYYMMDDHHMM)
#   DO_UPLOAD     true to send builds to TestFlight

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

require() {
  local name
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      echo "Missing required value: ${name}" >&2
      exit 1
    fi
  done
}

require APP_STORE_DISTRIBUTION_P12_BASE64 APP_STORE_DISTRIBUTION_P12_PASSWORD \
        ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY \
        APPLE_TEAM_ID APP_STORE_DISTRIBUTION

if [[ "${APP_STORE_DISTRIBUTION}" != Apple\ Distribution:*"(${APPLE_TEAM_ID})" ]]; then
  echo "APP_STORE_DISTRIBUTION does not belong to APPLE_TEAM_ID ${APPLE_TEAM_ID}." >&2
  exit 1
fi

PLATFORMS="${PLATFORMS:-all}"
# YYMMDD.R, with R the next unused revision for today. Derived here rather
# than in the workflow because it needs the App Store Connect key.
if [[ -z "${BUILD_NUMBER:-}" ]]; then
  export ASC_PRIVATE_KEY_PATH="${HOME}/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
  BUILD_NUMBER="$(python3 Scripts/next-build-number.py)"
fi
DO_UPLOAD="${DO_UPLOAD:-false}"

WORK_DIR="$(mktemp -d "${RUNNER_TEMP:-/tmp}/statusboard-release.XXXXXX")"
KEYCHAIN_PATH="${WORK_DIR}/statusboard-signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
P12_PATH="${WORK_DIR}/distribution.p12"
ASC_KEY_DIR="${HOME}/.appstoreconnect/private_keys"
ASC_KEY_PATH="${ASC_KEY_DIR}/AuthKey_${ASC_KEY_ID}.p8"
ORIGINAL_KEYCHAINS=()

while IFS= read -r keychain; do
  keychain="${keychain#*\"}"
  keychain="${keychain%\"*}"
  [[ -n "${keychain}" ]] && ORIGINAL_KEYCHAINS+=("${keychain}")
done < <(security list-keychains -d user)

cleanup() {
  local exit_code=$?
  set +e
  # Put the machine back exactly as it was found.
  if ((${#ORIGINAL_KEYCHAINS[@]})); then
    security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}"
  fi
  security delete-keychain "${KEYCHAIN_PATH}" >/dev/null 2>&1
  rm -f "${ASC_KEY_PATH}"
  rm -rf "${WORK_DIR}"
  exit "${exit_code}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "▸ Staging signing material"

printf '%s' "${APP_STORE_DISTRIBUTION_P12_BASE64}" | /usr/bin/base64 -D > "${P12_PATH}"
chmod 600 "${P12_PATH}"

security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
security set-keychain-settings -lut 21600 "${KEYCHAIN_PATH}"
security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN_PATH}"
security import "${P12_PATH}" \
  -k "${KEYCHAIN_PATH}" \
  -P "${APP_STORE_DISTRIBUTION_P12_PASSWORD}" \
  -T /usr/bin/codesign \
  -T /usr/bin/security
# Without this, codesign prompts for keychain access and hangs a headless build.
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s -k "${KEYCHAIN_PASSWORD}" \
  "${KEYCHAIN_PATH}" >/dev/null
# The ephemeral keychain goes first, but the original list has to stay: the
# Apple WWDR intermediate lives in the login keychain, and without it the
# imported certificate cannot build a chain — `find-identity -v` then reports
# "0 valid identities found" even though the import succeeded.
security list-keychains -d user -s "${KEYCHAIN_PATH}" "${ORIGINAL_KEYCHAINS[@]}"

if ! security find-identity -v -p codesigning "${KEYCHAIN_PATH}" \
     | grep -Fq "\"${APP_STORE_DISTRIBUTION}\""; then
  echo "The imported PKCS#12 does not contain ${APP_STORE_DISTRIBUTION}." >&2
  security find-identity -v -p codesigning "${KEYCHAIN_PATH}" >&2
  exit 1
fi
echo "  ✓ ${APP_STORE_DISTRIBUTION}"

mkdir -p "${ASC_KEY_DIR}"
printf '%s' "${ASC_PRIVATE_KEY}" > "${ASC_KEY_PATH}"
chmod 600 "${ASC_KEY_PATH}"
if ! grep -q "BEGIN PRIVATE KEY" "${ASC_KEY_PATH}"; then
  echo "ASC_PRIVATE_KEY does not look like a PEM private key." >&2
  exit 1
fi
echo "  ✓ App Store Connect key ${ASC_KEY_ID}"

# Every Release configuration signs manually, so all the App Store profiles
# have to be on disk before xcodebuild runs. Fetched from App Store Connect
# rather than carried as secrets, so a renewed profile needs no rotation here.
export ASC_PRIVATE_KEY_PATH="${ASC_KEY_PATH}"
if ! python3 Scripts/fetch-profiles.py; then
  echo "Could not install provisioning profiles." >&2
  exit 1
fi

export DEVELOPMENT_TEAM="${APPLE_TEAM_ID}"
export ASC_KEY_ID ASC_ISSUER_ID
# release.sh must not fall back to a developer's local .env on a build machine.
export ASC_ENV_FILE=/nonexistent

ARGS=(--build-number "${BUILD_NUMBER}" --platforms "${PLATFORMS}")
[[ "${DO_UPLOAD}" == "true" ]] && ARGS+=(--upload)

echo "▸ Scripts/release.sh ${ARGS[*]}"
./Scripts/release.sh "${ARGS[@]}"

# Put the new builds in front of testers, with the commit as release notes.
if [[ "${DO_UPLOAD}" == "true" ]]; then
  EXPECT_PLATFORMS="$(tr '\n' ',' < Artifacts/uploaded-platforms.txt 2>/dev/null || true)" \
  BUILD_NUMBER="${BUILD_NUMBER}" BETA_GROUP="${BETA_GROUP:-External Testers}" \
    python3 Scripts/submit-beta.py || echo "  (beta submission reported a problem; the uploads themselves succeeded)"
fi
