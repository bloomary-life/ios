#!/usr/bin/env bash
# Run the UI tests (BloomaryUITests scheme) on a simulator against the stage API,
# recording the run to a video.
#
# Usage:
#   BLOOMARY_DEMO_CODE=<code> bash scripts/ui-test.sh [simulator-name] [out-dir]
# Output: <out-dir>/ui-test.mp4, <out-dir>/UITests.xcresult (screenshots as attachments)
set -euo pipefail

SIM_NAME="${1:-iPhone 17 Pro}"
OUT="${2:-$(mktemp -d)}"
cd "$(dirname "$0")/.."

SIM_ID="$(xcrun simctl list devices available | awk -F'[()]' -v n="$SIM_NAME" '$0 ~ n" \\(" {print $2; exit}')"
[ -n "$SIM_ID" ] || { echo "simulator not found: $SIM_NAME" >&2; exit 1; }
xcrun simctl boot "$SIM_ID" 2>/dev/null || true
xcrun simctl uninstall "$SIM_ID" com.dailymind.bloomary 2>/dev/null || true

mkdir -p "$OUT"
rm -rf "$OUT/UITests.xcresult"
xcrun simctl io "$SIM_ID" recordVideo --codec=h264 --force "$OUT/ui-test.mp4" &
REC=$!
trap 'pkill -INT -f "recordVideo.*$OUT" 2>/dev/null; wait $REC 2>/dev/null || true' EXIT

TEST_RUNNER_BLOOMARY_DEMO_CODE="${BLOOMARY_DEMO_CODE:-}" \
xcodebuild test -project Bloomary.xcodeproj -scheme BloomaryUITests \
  -destination "id=$SIM_ID" -resultBundlePath "$OUT/UITests.xcresult"

echo "out: $OUT"
