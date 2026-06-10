#!/usr/bin/env bash
# The canonical Sonic-API fixtures live in server/tests/fixtures/ (see
# docs/SONIC-API.md). This copies them into the SonicClient test bundle so
# both sides keep testing against the same JSON. Run after editing fixtures;
# CI fails if the copies drift.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=server/tests/fixtures
DST=ios/Packages/SonicClient/Tests/SonicClientTests/Fixtures

if [[ "${1:-}" == "--check" ]]; then
    diff -r "$SRC" "$DST"
    echo "fixtures in sync"
else
    mkdir -p "$DST"
    cp "$SRC"/*.json "$DST"/
    echo "fixtures copied to $DST"
fi
