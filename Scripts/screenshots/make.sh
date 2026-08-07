#!/bin/bash
# Regenerate every App Store screenshot, end to end.
#
#   Scripts/screenshots/make.sh [raw-dir]
#
# Captures the simulators, captures the Mac, then composes the finished
# frames into Distribution/AppStore/Screenshots. See README.md for what has
# to be booted and built first.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
RAW="${1:-$REPO/build/screenshot-raw}"
OUT="$REPO/Distribution/AppStore/Screenshots"

mkdir -p "$RAW" "$OUT"

echo "== simulators"
"$HERE/capture_boards.sh" "$RAW"

echo "== macOS"
"$HERE/capture_mac.sh" "$RAW"

echo "== compose"
python3 "$HERE/compose.py" "$RAW" "$OUT"

echo
echo "screenshots -> $OUT"
