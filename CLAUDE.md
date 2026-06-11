# Jellyamp — agent notes

Plexamp-style iOS music player for Jellyfin. Monorepo: `ios/` (SwiftUI app +
local SPM packages), `server/` (optional FastAPI sonic-analysis companion),
`docs/` (architecture + contracts). Roadmap: `docs/ROADMAP.md`.

## Ground rules

- **The app shell stays thin.** Logic that doesn't need Apple frameworks goes
  into `ios/Packages/{JellyampCore,JellyfinBackend,SonicClient}` — those build
  and test on Linux and are the primary safety net.
- **`docs/SONIC-API.md` is the contract** between `SonicClient` and
  `server/`. Canonical JSON fixtures live in `server/tests/fixtures/`; after
  editing them run `scripts/sync-fixtures.sh` (CI fails if copies drift).
- The companion server is **optional** for users. The app must work against a
  plain Jellyfin server via `JellyfinFallbackSonicProvider`; UI affordances
  follow `SonicCapabilities`.
- The Xcode project is generated (`cd ios && xcodegen generate`); never check
  in `*.xcodeproj`. App-target settings live in `ios/project.yml`.

## Verification

| What | How |
|---|---|
| Swift packages | `swift test` inside each package (Linux OK; CI: core-linux.yml uses the `swift:6.0` container) |
| Server | `cd server && .venv/bin/pytest -q && .venv/bin/ruff check .` (setup: `python3 -m venv .venv && .venv/bin/pip install -e ".[dev]"`) |
| App target | macOS only: `xcodegen generate` + xcodebuild (CI: ios.yml on PRs) |

Notes for sandboxed environments: Docker Hub blob pulls and swift.org may be
blocked — rely on the GitHub Actions workflows for Swift verification then.
A stale `server/data/jellyamp.sqlite` from older schema versions breaks
startup; delete it (it's gitignored, there are no migrations pre-1.0).

## Gotchas already hit

- Jellyfin DTOs use PascalCase wire names; a property named `Type` must be
  written `` var `Type` `` (Swift keyword clash).
- Jellyfin omits `MediaSources`/`Genres` from `/Items` unless requested via
  `fields=`.
- Transcoded `/Audio/{id}/universal` streams are not byte-seekable — seek by
  re-requesting with `startTimeTicks`.
