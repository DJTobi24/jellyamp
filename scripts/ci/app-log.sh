#!/usr/bin/env bash
# Records what the app logs on a simulator while tests run, and prints it.
#
#   scripts/ci/app-log.sh start <simulator udid> <log file>
#   scripts/ci/app-log.sh show <log file> [lines]
#
# The app logs through os.Logger (subsystem dev.djtobi.Jellyamp: Playback,
# Streaming, Downloads, …). None of that reaches xcodebuild's output, and it
# is exactly what explains a failed playback or download test: which track
# was loaded, whether the engine started, why a track was skipped.
# `start` leaves a `log stream` running in the background (it ends with the
# CI job); `show` prints the end of the recording.
set -uo pipefail

case "${1:-}" in
start)
    udid="${2:?simulator udid}"
    file="${3:?log file}"
    mkdir -p "$(dirname "$file")"
    nohup xcrun simctl spawn "$udid" log stream --level info --style compact \
        --predicate 'subsystem == "dev.djtobi.Jellyamp"' >"$file" 2>&1 &
    echo "recording the app log to $file (pid $!)"
    ;;
show)
    file="${2:?log file}"
    lines="${3:-400}"
    if [ -s "$file" ]; then
        echo "Last $lines lines of the app log ($file):"
        tail -n "$lines" "$file" | cut -c1-500
    else
        echo "(no app log at $file)"
    fi
    ;;
*)
    echo "usage: $0 start <udid> <file> | show <file> [lines]" >&2
    exit 64
    ;;
esac
exit 0
