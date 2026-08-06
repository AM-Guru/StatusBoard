#!/usr/bin/env bash
#
# Archive, export and (optionally) upload Status Board to TestFlight.
# Covers iOS, macOS and tvOS; the watch app rides along inside the iOS build.
#
# Runs identically on CI and by hand:
#     ./Scripts/release.sh --platforms all --upload   (ios | macos | tvos | all)
#     ssh media 'cd ~/Repo/StatusBoard && ./Scripts/release.sh --upload'
#
# Credentials are read from the environment, or from ~/Repo/appstoreconnect/.env
# when present, so a local run needs no arguments.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PLATFORMS="all"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
DO_UPLOAD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platforms) PLATFORMS="$2"; shift 2 ;;
    --build-number) BUILD_NUMBER="$2"; shift 2 ;;
    --upload) DO_UPLOAD=1; shift ;;
    -h|--help)
      sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# ── Credentials ───────────────────────────────────────────────────────────
ENV_FILE="${ASC_ENV_FILE:-$HOME/Repo/appstoreconnect/.env}"
if [[ -z "${ASC_KEY_ID:-}" && -f "$ENV_FILE" ]]; then
  # Parsed rather than sourced: values may contain spaces without quoting,
  # which `source` would try to execute. Only the keys we need are read.
  while IFS='=' read -r key value; do
    key="${key#"${key%%[![:space:]]*}"}"          # trim leading space
    [[ "$key" =~ ^(ASC_KEY_ID|ASC_ISSUER_ID|ASC_PRIVATE_KEY_PATH|DEVELOPMENT_TEAM)$ ]] || continue
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
    [[ -z "${!key:-}" ]] && export "$key=$value"
  done < "$ENV_FILE"
fi
: "${ASC_KEY_ID:?ASC_KEY_ID is required}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required}"

# xcodebuild only authenticates against the developer portal reliably when the
# key sits in the well-known directory and is referenced by id — passing
# -authenticationKeyPath instead fails with "Authentication failed: Make sure a
# bearer token was provided". So the key is copied there and the path flag is
# never used.
KEY_NAME="AuthKey_${ASC_KEY_ID}.p8"
KEY_DIR="$HOME/.appstoreconnect/private_keys"
KEY_FOUND=""
for dir in "$KEY_DIR" "$HOME/private_keys" "$HOME/Repo/appstoreconnect/private_keys"; do
  [[ -f "$dir/$KEY_NAME" ]] && KEY_FOUND="$dir/$KEY_NAME" && break
done
if [[ -z "$KEY_FOUND" && -n "${ASC_PRIVATE_KEY_PATH:-}" && -f "${ASC_PRIVATE_KEY_PATH/#\~/$HOME}" ]]; then
  KEY_FOUND="${ASC_PRIVATE_KEY_PATH/#\~/$HOME}"
fi
[[ -n "$KEY_FOUND" ]] || { echo "Could not find $KEY_NAME" >&2; exit 1; }
if [[ "$KEY_FOUND" != "$KEY_DIR/$KEY_NAME" ]]; then
  mkdir -p "$KEY_DIR"
  cp "$KEY_FOUND" "$KEY_DIR/$KEY_NAME"
  chmod 600 "$KEY_DIR/$KEY_NAME"
fi

# project.yml already carries the team, so a local run needs no extra setup.
if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  DEVELOPMENT_TEAM="$(awk -F': *' '/^ *DEVELOPMENT_TEAM:/ {print $2; exit}' project.yml)"
  export DEVELOPMENT_TEAM
fi
: "${DEVELOPMENT_TEAM:?DEVELOPMENT_TEAM is required (your 10-character Apple team id)}"

ARTIFACTS="$REPO_ROOT/Artifacts"
mkdir -p "$ARTIFACTS"

echo "▸ Status Board release"
echo "  build number : $BUILD_NUMBER"
echo "  platforms    : $PLATFORMS"
echo "  upload       : $([[ $DO_UPLOAD == 1 ]] && echo yes || echo no)"
echo "  team         : $DEVELOPMENT_TEAM"

command -v xcodegen >/dev/null || { echo "xcodegen not installed (brew install xcodegen)" >&2; exit 1; }
xcodegen generate

# ── Helpers ───────────────────────────────────────────────────────────────
archive() {                     # archive <scheme> <destination> <archive path>
  echo "▸ Archiving $1"
  xcodebuild -project StatusBoard.xcodeproj \
    -scheme "$1" -destination "$2" -configuration Release \
    -archivePath "$3" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    -allowProvisioningUpdates \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    clean archive
}

export_archive() {              # export_archive <archive> <plist> <out dir>
  echo "▸ Exporting $(basename "$1")"
  xcodebuild -exportArchive \
    -archivePath "$1" -exportOptionsPlist "$2" -exportPath "$3" \
    -allowProvisioningUpdates \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
}

upload() {                      # upload <file> <platform>
  [[ $DO_UPLOAD == 1 ]] || { echo "  (skipping upload)"; return; }
  echo "▸ Uploading $(basename "$1") to App Store Connect"
  xcrun altool --upload-app --type "$2" --file "$1" \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
}

# Every Release configuration signs manually (see project.yml), so each export
# has to name the profile for every bundle id it contains.
IOS_PROFILES='  <dict>
    <key>guru.am.StatusBoard</key><string>Status Board iOS App Store</string>
    <key>guru.am.StatusBoard.widgets</key><string>Status Board iOS Widgets App Store</string>
    <key>guru.am.StatusBoard.watchkitapp</key><string>Status Board Watch App Store</string>
    <key>guru.am.StatusBoard.watchkitapp.widgets</key><string>Status Board Watch Widgets App Store</string>
  </dict>'
TVOS_PROFILES='  <dict>
    <key>guru.am.StatusBoard</key><string>Status Board tvOS App Store</string>
  </dict>' 

make_export_plist() {           # make_export_plist <path> <method> <destination> [profiles-dict]
  local profiles="${4:-}"
  local signing_block="  <key>signingStyle</key><string>automatic</string>"
  if [[ -n "$profiles" ]]; then
    signing_block="  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key>
$profiles"
  fi
  cat > "$1" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>$2</string>
  <key>destination</key><string>$3</string>
  <key>teamID</key><string>$DEVELOPMENT_TEAM</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
$signing_block
</dict>
</plist>
PLIST
}

# ── Per-platform pipeline ────────────────────────────────────────────────
# The watch app is not listed here on purpose: it is a companion app embedded
# inside the iOS build, so it ships with the iPhone .ipa.
wants() {                       # wants <platform>
  [[ "$PLATFORMS" == "all" || "$PLATFORMS" == "both" || "$PLATFORMS" == "$1" ]]
}

ship() {                        # ship <scheme> <destination> <slug> <altool type> <ext> [profiles-dict]
  local scheme="$1" destination="$2" slug="$3" type="$4" ext="$5" manual_profile="${6:-}"
  local archive_path="$ARTIFACTS/$scheme.xcarchive"
  archive "$scheme" "$destination" "$archive_path"
  make_export_plist "$ARTIFACTS/ExportOptions-$slug.plist" "app-store-connect" "export" "$manual_profile"
  export_archive "$archive_path" "$ARTIFACTS/ExportOptions-$slug.plist" "$ARTIFACTS/$slug"
  local product
  product="$(find "$ARTIFACTS/$slug" -maxdepth 1 -name "*.$ext" | head -1)"
  [[ -n "$product" ]] || { echo "No .$ext produced for $scheme" >&2; exit 1; }
  upload "$product" "$type"
}

# `both` is kept as a synonym for `all` so older invocations still work.
if [[ "$PLATFORMS" == "both" ]]; then
  echo "  note: --platforms both now means all three (iOS, macOS, tvOS)"
fi

wants ios   && ship "StatusBoard-iOS"   "generic/platform=iOS"   ios   ios   ipa "$IOS_PROFILES"
wants macos && ship "StatusBoard-macOS" "generic/platform=macOS" macos macos pkg
wants tvos  && ship "StatusBoard-tvOS"  "generic/platform=tvOS"  tvos  appletvos ipa "$TVOS_PROFILES"

echo "✓ Done. Artifacts in $ARTIFACTS"
