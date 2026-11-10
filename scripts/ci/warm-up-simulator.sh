#!/usr/bin/env bash
# Starts the app once on a simulator so that the simulator's audio service
# is up before the tests need it.
#
#   scripts/ci/warm-up-simulator.sh <simulator udid> <path to Jellyamp.app>
#
# Why: on a freshly booted CI simulator the first process that opens the
# audio output (AVAudioEngine's output unit) can wait for the audio service
# for so long that AudioToolbox gives up and aborts the process ("RPC
# timeout" in AURemoteIO) — an abort inside the system framework that no
# code of ours can catch. If that process is the app under test, the first
# test fails for a reason that has nothing to do with the app. The second
# process finds the service running. So the app is launched here in demo
# mode (signing in builds the audio engine) until the engine reports itself,
# at most twice, and is terminated again.
#
# Never fails the job: this is only a warm-up; the tests decide.
set -uo pipefail

udid="${1:?simulator udid}"
app="${2:?path to the built .app}"
bundle_id="dev.djtobi.jellyamp"
# Logged by AudioEnginePlayer when its engine is built (Logger, info level).
ready_message="AudioEnginePlayer init"

if [ ! -d "$app" ]; then
    echo "warm-up: $app does not exist, skipping"
    exit 0
fi

xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
xcrun simctl install "$udid" "$app" || { echo "warm-up: could not install the app, skipping"; exit 0; }

log="$(mktemp)"
xcrun simctl spawn "$udid" log stream --level info --style compact \
    --predicate 'subsystem == "dev.djtobi.Jellyamp" AND category == "Playback"' >"$log" 2>&1 &
stream_pid=$!
trap 'kill "$stream_pid" >/dev/null 2>&1; rm -f "$log"' EXIT
sleep 2

for attempt in 1 2; do
    # The system's own timeout is about a minute and a half; a second
    # attempt either works at once or not at all.
    if [ "$attempt" -eq 1 ]; then limit=150; else limit=60; fi
    started="$(date +%s)"
    xcrun simctl launch "$udid" "$bundle_id" -JellyampDemo YES -JellyampResetState YES >/dev/null 2>&1 \
        || echo "warm-up: launch failed (attempt $attempt)"
    ready=""
    while [ $(( $(date +%s) - started )) -lt "$limit" ]; do
        if grep -q "$ready_message" "$log"; then ready=yes; break; fi
        sleep 2
    done
    # A moment for the engine's first conversation with the audio service.
    sleep 3
    xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
    if [ -n "$ready" ]; then
        echo "warm-up: the audio engine came up after $(( $(date +%s) - started )) s (attempt $attempt)"
        exit 0
    fi
    echo "warm-up: no audio engine after $(( $(date +%s) - started )) s (attempt $attempt)"
done
echo "warm-up: giving up; the tests run anyway"
exit 0
