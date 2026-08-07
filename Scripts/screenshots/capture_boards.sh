#!/bin/bash
# Capture one raw screenshot per board, per simulator.
#
#   capture_boards.sh <output-dir>
#
# Reseeds with the wanted board first and relaunches rather than tapping
# through the sidebar: DashboardStore selects dashboards.first at load, so
# ordering the file is a reliable substitute for six taps on five devices.
set -euo pipefail

OUT="${1:?usage: capture_boards.sh <output-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT"

# device-key : udid : bundle-id : settle-seconds
DEVICES=(
    "iphone:5112BE89-853C-488B-A34C-205BF8A9C21D:guru.am.StatusBoard:7"
    "ipad:F65F12E5-4B44-432C-8C36-A27F6530C576:guru.am.StatusBoard:7"
    "appletv:C0552996-B206-44F6-8006-6B0EC31B2E39:guru.am.StatusBoard:10"
    "watch:83F28B9D-0B00-4619-BA79-93C5A30C54D0:guru.am.StatusBoard.watchkitapp:8"
)

BOARDS=("Home" "School" "Mac Vitals" "Glass" "World Clocks" "Themes")

for entry in "${DEVICES[@]}"; do
    IFS=: read -r key udid bundle settle <<<"$entry"
    if ! xcrun simctl list devices booted | grep -q "$udid"; then
        echo "skip $key — not booted" >&2
        continue
    fi
    for boardName in "${BOARDS[@]}"; do
        slug="$(echo "$boardName" | tr '[:upper:] ' '[:lower:]-')"
        "$HERE/seed_simulator.sh" "$udid" "$bundle" "$boardName" >/dev/null
        xcrun simctl launch "$udid" "$bundle" >/dev/null 2>&1 || true
        sleep "$settle"
        xcrun simctl io "$udid" screenshot "$OUT/$key-board-$slug.png" >/dev/null 2>&1
        echo "captured $key / $boardName"
    done
    # Leave every device on the hero board so the tap-driven captures that
    # follow all start from the same place.
    "$HERE/seed_simulator.sh" "$udid" "$bundle" "Home" >/dev/null
    xcrun simctl launch "$udid" "$bundle" >/dev/null 2>&1 || true
done

echo "raw board captures -> $OUT"
