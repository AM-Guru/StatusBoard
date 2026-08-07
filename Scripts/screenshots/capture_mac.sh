#!/bin/bash
# Capture one raw screenshot per board from the macOS app.
#
#   capture_mac.sh <output-dir> [app-bundle]
#
# Runs a *development* build so it writes to ~/Library/Application Support/
# StatusBoard rather than the sandboxed container the release app uses — the
# demo seed must never land on top of somebody's real boards.
#
# The window is captured by id via `screencapture -l`, which needs no
# permission. Do not reach for AppleScript here: System Events wants
# Accessibility access and simply hangs waiting for it in a non-interactive
# session.
set -euo pipefail

OUT="${1:?usage: capture_mac.sh <output-dir> [app-bundle]}"
APP="${2:-build/dd-mac/Build/Products/Debug/Status Board.app}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SUPPORT="$HOME/Library/Application Support/StatusBoard"
mkdir -p "$OUT"

if [ ! -d "$APP" ]; then
    echo "no app at $APP — build StatusBoard-macOS first" >&2
    exit 1
fi

BOARDS=("Home" "School" "Mac Vitals" "Glass" "World Clocks" "Themes")

for boardName in "${BOARDS[@]}"; do
    slug="$(echo "$boardName" | tr '[:upper:] ' '[:lower:]-')"

    pkill -f "$APP/Contents/MacOS" 2>/dev/null || true
    sleep 2
    python3 "$HERE/seed_demo_data.py" --first "$boardName" "$SUPPORT" >/dev/null
    open -n "$APP"
    sleep 9

    # Match on the pid we just launched, not the app name: a released copy in
    # /Applications shares this build's bundle id and display name, and
    # capturing that one would put real dashboards in a store screenshot.
    pid="$(pgrep -n -f "$APP/Contents/MacOS" || true)"
    if [ -z "$pid" ]; then
        echo "the dev build did not start for $boardName" >&2
        continue
    fi
    # Largest window wins, and no size is pinned: the window frame is autosaved
    # per bundle id, so this opens at whatever the last copy was left at. The
    # composer scales the capture into a fixed-width bezel regardless.
    win="$(swift "$HERE/window_bounds.swift" "Status Board" "$pid" | head -1 | cut -f1)"
    if [ -z "$win" ]; then
        echo "no window on screen for $boardName" >&2
        continue
    fi
    screencapture -x -o -l"$win" "$OUT/mac-board-$slug.png"
    echo "captured mac / $boardName"
done

echo "raw mac captures -> $OUT"
