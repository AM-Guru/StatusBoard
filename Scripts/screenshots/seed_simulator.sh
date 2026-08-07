#!/bin/bash
# Seed a booted simulator with the App Store demo boards.
#
#   seed_simulator.sh <device-udid> [bundle-id]
#
# Terminates the app first: DashboardStore writes dashboards.json back out on
# every mutation, so seeding underneath a running app is a race the app wins.
set -euo pipefail

UDID="${1:?usage: seed_simulator.sh <device-udid> [bundle-id] [board-name]}"
BUNDLE="${2:-guru.am.StatusBoard}"
FIRST="${3:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"

xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true

DATA="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)"
SUPPORT="$DATA/Library/Application Support/StatusBoard"

if [ -n "$FIRST" ]; then
    python3 "$HERE/seed_demo_data.py" --first "$FIRST" "$SUPPORT"
else
    python3 "$HERE/seed_demo_data.py" "$SUPPORT"
fi

# The board pinned per-device on tvOS/watchOS is held in defaults, and it now
# points at a board that no longer exists. Clearing it lets the app fall back
# to the first board — "Home", which is the hero shot.
PLIST="$DATA/Library/Preferences/$BUNDLE.plist"
if [ -f "$PLIST" ]; then
    for key in sb.tv.boardID sb.selectedDashboardID; do
        /usr/libexec/PlistBuddy -c "Delete :$key" "$PLIST" 2>/dev/null || true
    done
fi

echo "seeded $BUNDLE on $UDID"
