#!/usr/bin/env bash
#
# TestFlight and App Store builds use CloudKit Production. Development creates
# record types on first write; Production deliberately does not. Verify the
# exact contract Status Board uses before uploading another inaccessible build.

set -euo pipefail

: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"

# Schema inspection is a valuable release guard, but the management token is
# not app-signing material and older repositories will not have one yet. Do not
# turn that missing optional credential into a total release outage. Once the
# secret is configured, an incomplete Production schema remains a hard failure.
if [[ -z "${CLOUDKIT_MANAGEMENT_TOKEN:-}" ]]; then
  echo "::warning title=CloudKit schema not verified::CLOUDKIT_MANAGEMENT_TOKEN is not configured; continuing without the Production schema preflight."
  echo "  · Add the GitHub Actions secret after creating a management token in CloudKit Console Settings."
  exit 0
fi

container_id="iCloud.guru.am.statusboard"
schema_file="$(mktemp /tmp/statusboard-production-schema.XXXXXX.ckdb)"
trap '/usr/bin/unlink "$schema_file" 2>/dev/null || true' EXIT

echo "▸ CloudKit Production schema"
xcrun cktool export-schema \
  --team-id "$APPLE_TEAM_ID" \
  --container-id "$container_id" \
  --environment production \
  --output-file "$schema_file"

if ! grep -Eiq 'RECORD[[:space:]]+TYPE[[:space:]]+"?Dashboard"?' "$schema_file"; then
  echo "  ✗ Production has no Dashboard record type." >&2
  echo "    Deploy the Development schema in CloudKit Console, then rerun the release." >&2
  exit 1
fi

if ! grep -Eiq '"?payload"?[[:space:]]+BYTES' "$schema_file"; then
  echo "  ✗ Production Dashboard has no payload BYTES field." >&2
  echo "    Add it in Development and deploy the schema in CloudKit Console." >&2
  exit 1
fi

echo "  ✓ ${container_id} Production contains Dashboard.payload (BYTES)"
