#!/usr/bin/env bash
# Checks that an .xcarchive contains what an App Store upload needs.
#
#   scripts/ci/verify-archive.sh ios/build/Jellyamp.xcarchive
#
# Works on unsigned archives (CI smoke job) and signed ones alike. Everything
# checked here is something App Store Connect rejects or silently mishandles
# when it is missing, and that the simulator build never exercises.
set -euo pipefail

archive="${1:?usage: $0 <path to .xcarchive>}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
app="$archive/Products/Applications/Jellyamp.app"
plist="$app/Info.plist"
failures=0

fail() {
    echo "error: $*" >&2
    failures=$((failures + 1))
}

if [ ! -f "$plist" ]; then
    echo "error: $plist not found; the archive has no Jellyamp.app" >&2
    exit 1
fi

value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true
}

expect() {
    local key="$1" expected="$2" actual
    actual="$(value "$key")"
    if [ "$actual" = "$expected" ]; then
        echo "ok: $key = $actual"
    else
        fail "Info.plist $key is '$actual', expected '$expected'"
    fi
}

# Version comes from the build settings in project.yml, not a stale literal.
expected_version="$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)" *$/\1/p' "$repo/ios/project.yml" | head -n 1)"
expected_bundle_id="$(sed -n 's/^ *PRODUCT_BUNDLE_IDENTIFIER: *\([^ ]*\) *$/\1/p' "$repo/ios/project.yml" | head -n 1)"

expect CFBundleIdentifier "$expected_bundle_id"
expect CFBundleShortVersionString "$expected_version"
expect ITSAppUsesNonExemptEncryption false
expect LSApplicationCategoryType public.app-category.music
expect UIBackgroundModes:0 audio
expect NSAppTransportSecurity:NSAllowsArbitraryLoads true

build_number="$(value CFBundleVersion)"
case "$build_number" in
    "" | *[!0-9.]*) fail "CFBundleVersion '$build_number' is not numeric" ;;
    *) echo "ok: CFBundleVersion = $build_number" ;;
esac

# iOS ignores NSAllowsArbitraryLoads when this key is present.
if [ -n "$(value NSAppTransportSecurity:NSAllowsLocalNetworking)" ]; then
    fail "NSAllowsLocalNetworking is set; it disables NSAllowsArbitraryLoads"
fi

# The asset catalog compiler adds the icon keys; no icon means ITMS-90713.
if plutil -p "$plist" | grep -q '"CFBundleIconName" => "AppIcon"'; then
    echo "ok: CFBundleIconName = AppIcon"
else
    fail "Info.plist has no CFBundleIconName; the app icon was not compiled in"
fi

for resource in Assets.car PrivacyInfo.xcprivacy; do
    if [ -f "$app/$resource" ]; then
        echo "ok: $resource is in the bundle"
    else
        fail "$resource is missing from the app bundle"
    fi
done

# German is compiled from the String Catalogs at build time; a catalog that
# silently drops out of the target would ship an English-only app.
for resource in de.lproj/Localizable.strings de.lproj/InfoPlist.strings de.lproj/AppShortcuts.strings; do
    if [ -f "$app/$resource" ]; then
        echo "ok: $resource is in the bundle"
    else
        fail "$resource is missing from the app bundle (German localization)"
    fi
done

if [ -f "$app/PrivacyInfo.xcprivacy" ] && ! plutil -lint "$app/PrivacyInfo.xcprivacy" >/dev/null; then
    fail "PrivacyInfo.xcprivacy is not a valid property list"
fi

# The demo library's audio loops ship as a SwiftPM resource bundle
# (ios/Packages/JellyfinDemo). Without them "Try the Demo" — what App Review
# uses — plays nothing.
loops="$(find "$app" -name '*.aac' -path '*Loops*' | wc -l | tr -d ' ')"
if [ "$loops" -ge 24 ]; then
    echo "ok: $loops demo audio loops are in the bundle"
else
    fail "only $loops of 24 demo audio loops are in the app bundle (JellyfinDemo resources)"
fi

if [ "$failures" -gt 0 ]; then
    echo "$failures problem(s) in $archive" >&2
    exit 1
fi
echo "Archive looks ready for the App Store."
