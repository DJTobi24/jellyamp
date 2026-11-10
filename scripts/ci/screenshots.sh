#!/usr/bin/env bash
# Captures the App Store screenshots for one device family and language.
#
#   scripts/ci/screenshots.sh <iphone|ipad> <language> [output-dir]
#   scripts/ci/screenshots.sh iphone en-US
#   scripts/ci/screenshots.sh ipad de-DE ios/fastlane/screenshots
#
# Runs the ScreenshotTests UI-test class in demo mode on the simulator App
# Store Connect wants screenshots from (6.9" iPhone / 13" iPad, or the
# nearest the machine has), then exports the screenshots from the result
# bundle to <output-dir>/<language>/NN-name-<family>.png. The default output
# directory is ios/fastlane/screenshots, where `fastlane release` picks them
# up. Needs the generated Xcode project (cd ios && xcodegen generate).
#
# Environment:
#   SCREENSHOT_SKIP_BUILD=1   use `test-without-building` (products already
#                             built into ios/build/DerivedData)
set -uo pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: $0 <iphone|ipad> <language> [output-dir]" >&2
    exit 64
fi

family="$1"
language="$2"
root="$(cd "$(dirname "$0")/../.." && pwd)"
output="${3:-$root/ios/fastlane/screenshots}"
case "$output" in
    /*) ;;
    *) output="$PWD/$output" ;;
esac

udid="$(python3 "$root/scripts/ci/pick-simulator.py" --family "$family" --screenshots)" || exit 1

# A booted simulator with the marketing status bar (9:41, full battery).
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
xcrun simctl status_bar "$udid" override \
    --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 \
    2>/dev/null || echo "note: could not override the status bar on this simulator" >&2

cd "$root/ios" || exit 1
result="build/Screenshots-$family-$language.xcresult"
rm -rf "$result"

action=(test)
if [ -n "${SCREENSHOT_SKIP_BUILD:-}" ]; then
    action=(test-without-building)
fi

# TEST_RUNNER_* variables reach the test process with the prefix removed.
TEST_RUNNER_SCREENSHOT_LANGUAGE="$language" ../scripts/ci/xcodebuild.sh "screenshots-$family-$language" \
    "${action[@]}" \
    -project Jellyamp.xcodeproj -scheme JellyampUITests \
    -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath build/DerivedData \
    -only-testing:JellyampUITests/ScreenshotTests \
    -parallel-testing-enabled NO \
    -resultBundlePath "$result"
status=$?

# Whatever was captured before a failure is still worth having.
python3 "$root/scripts/ci/export-xcresult-attachments.py" "$result" "$output/$language" --suffix "$family"

exit "$status"
