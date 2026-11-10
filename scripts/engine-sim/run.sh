#!/usr/bin/env bash
# Behavioural simulation of AudioEnginePlayer on Linux (see make.py).
#
#   scripts/engine-sim/run.sh                      # reports go nowhere
#   JELLYFIN_TEST_URL=http://localhost:8096 scripts/engine-sim/run.sh
#                                                  # + checks play counts on a real server
#   SIM_VERBOSE=1 ...                              # print the player's log lines
#
# Takes about a minute (the fake audio clock is the wall clock).
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

python3 "$root/scripts/engine-sim/make.py" "$root" "$out"

env_args=()
[ -n "${JELLYFIN_TEST_URL:-}" ] && env_args+=(-e "JELLYFIN_TEST_URL=$JELLYFIN_TEST_URL")
[ -n "${SIM_VERBOSE:-}" ] && env_args+=(-e "SIM_VERBOSE=1")

docker run --rm --network host "${env_args[@]}" \
    -v "$root":/w:ro -v "$out":/s -w /s \
    "${SWIFT_IMAGE:-mirror.gcr.io/library/swift:6.0}" \
    swift run Sim
