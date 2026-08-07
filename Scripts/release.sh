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
# Environment, then ~/Repo/appstoreconnect/.env, then the login keychain. The
# resolver also copies the .p8 into ~/.appstoreconnect/private_keys, which is
# the only place xcodebuild reliably reads it from, and prints the page that
# issues these values when it comes up empty.
source "$REPO_ROOT/Scripts/asc-credentials.sh"
asc_resolve_credentials || { asc_credentials_help; exit 1; }

# project.yml already carries the team, so a local run needs no extra setup.
if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  DEVELOPMENT_TEAM="$(awk -F': *' '/^ *DEVELOPMENT_TEAM:/ {print $2; exit}' project.yml)"
  export DEVELOPMENT_TEAM
fi
: "${DEVELOPMENT_TEAM:?DEVELOPMENT_TEAM is required (your 10-character Apple team id)}"

ARTIFACTS="$REPO_ROOT/Artifacts"
mkdir -p "$ARTIFACTS"
rm -f "$ARTIFACTS/uploaded-platforms.txt"

echo "▸ Status Board release"
echo "  build number : $BUILD_NUMBER"
echo "  platforms    : $PLATFORMS"
echo "  upload       : $([[ $DO_UPLOAD == 1 ]] && echo yes || echo no)"
echo "  team         : $DEVELOPMENT_TEAM"
# Which source won matters when a run authenticates as the wrong team; the ids
# themselves stay out of the log.
echo "  credentials  : key id from ${ASC_KEY_ID_ORIGIN:-unknown}, .p8 from ${ASC_PRIVATE_KEY_ORIGIN:-unknown}"

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
MACOS_PROFILES='  <dict>
    <key>guru.am.StatusBoard</key><string>Status Board macOS App Store</string>
    <key>guru.am.StatusBoard.widgets</key><string>Status Board macOS Widgets App Store</string>
  </dict>' 

make_export_plist() {           # make_export_plist <path> <method> <destination> [profiles-dict] [installer-cert]
  local profiles="${4:-}" installer="${5:-}"
  local signing_block="  <key>signingStyle</key><string>automatic</string>"
  if [[ -n "$profiles" ]]; then
    signing_block="  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key>
$profiles"
  fi
  # Manual signing means Xcode will not go looking for the installer identity
  # on its own, so the macOS leg has to name it. Only the .pkg export has one.
  if [[ -n "$installer" ]]; then
    signing_block="$signing_block
  <key>installerSigningCertificate</key><string>$installer</string>"
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

ship() {                        # ship <scheme> <destination> <slug> <altool type> <ext> [profiles-dict] [installer-cert]
  local scheme="$1" destination="$2" slug="$3" type="$4" ext="$5" manual_profile="${6:-}" installer="${7:-}"
  local archive_path="$ARTIFACTS/$scheme.xcarchive"
  archive "$scheme" "$destination" "$archive_path"
  make_export_plist "$ARTIFACTS/ExportOptions-$slug.plist" "app-store-connect" "export" "$manual_profile" "$installer"
  export_archive "$archive_path" "$ARTIFACTS/ExportOptions-$slug.plist" "$ARTIFACTS/$slug"
  local product
  product="$(find "$ARTIFACTS/$slug" -maxdepth 1 -name "*.$ext" | head -1)"
  [[ -n "$product" ]] || { echo "No .$ext produced for $scheme" >&2; exit 1; }
  upload "$product" "$type"
  # Record what really went up: the beta step must wait for exactly these and
  # complain if one never appears, rather than quietly submitting a subset.
  if [[ $DO_UPLOAD == 1 ]]; then
    case "$type" in
      ios) echo IOS ;;
      appletvos) echo TV_OS ;;
      macos) echo MAC_OS ;;
    esac >> "$ARTIFACTS/uploaded-platforms.txt"
  fi
}

# `both` is kept as a synonym for `all` so older invocations still work.
if [[ "$PLATFORMS" == "both" ]]; then
  echo "  note: --platforms both now means all three (iOS, macOS, tvOS)"
fi

wants ios   && ship "StatusBoard-iOS"   "generic/platform=iOS"   ios   ios   ipa "$IOS_PROFILES"
# A Mac App Store .pkg is signed by a second certificate, separate from the one
# that signs the app. App Store Connect calls it "Mac Installer Distribution";
# the certificate itself is issued with the common name "3rd Party Mac Developer
# Installer", and that is the only name the keychain knows it by — matching on
# Apple's label instead finds nothing even when the certificate is installed.
# Without it exportArchive fails after a full archive, so check first and say
# plainly why macOS was left out rather than failing the whole release.
if wants macos; then
  MACOS_INSTALLER_IDENTITY="$(security find-identity -p basic -v 2>/dev/null \
    | sed -n 's/.*"\(3rd Party Mac Developer Installer[^"]*\)".*/\1/p' | head -1)"
  if [[ -n "$MACOS_INSTALLER_IDENTITY" ]]; then
    echo "▸ macOS installer identity: $MACOS_INSTALLER_IDENTITY"
    ship "StatusBoard-macOS" "generic/platform=macOS" macos macos pkg "$MACOS_PROFILES" \
         "$MACOS_INSTALLER_IDENTITY"
  else
    echo "▸ SKIPPING macOS"
    echo "  No '3rd Party Mac Developer Installer' certificate for team $DEVELOPMENT_TEAM."
    echo "  The app signs fine; the installer package cannot be signed without it."
    echo "  Create one at https://developer.apple.com/account/resources/certificates"
    echo "  (Mac Installer Distribution), then add it to the keychain — on CI, as"
    echo "  the APP_STORE_INSTALLER_P12_BASE64 secret."
    SKIPPED_MACOS=1
  fi
fi
wants tvos  && ship "StatusBoard-tvOS"  "generic/platform=tvOS"  tvos  appletvos ipa "$TVOS_PROFILES"

if [[ "${SKIPPED_MACOS:-0}" == 1 ]]; then
  echo "✓ Done (macOS skipped — see above). Artifacts in $ARTIFACTS"
else
  echo "✓ Done. Artifacts in $ARTIFACTS"
fi
