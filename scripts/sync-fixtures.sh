#!/usr/bin/env bash
# The canonical Sonic-API fixtures live in server/tests/fixtures/ (see
# docs/SONIC-API.md). This mirrors them into the SonicClient test bundle so
# both sides keep testing against the same JSON. Run after editing fixtures;
# CI fails if the copies drift (`--check`).
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=server/tests/fixtures
DST=ios/Packages/SonicClient/Tests/SonicClientTests/Fixtures

if [[ "${1:-}" == "--check" ]]; then
    if ! diff -r "$SRC" "$DST"; then
        echo "fixtures differ: run scripts/sync-fixtures.sh and commit the result" >&2
        exit 1
    fi
    echo "fixtures in sync"
else
    mkdir -p "$DST"
    # Mirror, not just copy: a fixture deleted on the server side must not
    # linger in the client bundle (the check would flag it forever).
    find "$DST" -maxdepth 1 -name '*.json' -delete
    cp "$SRC"/*.json "$DST"/
    echo "fixtures copied to $DST"
fi
