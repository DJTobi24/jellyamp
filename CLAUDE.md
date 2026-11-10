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
- iOS 26 / Liquid Glass APIs are used only via the gated helpers in
  `ios/Jellyamp/DesignSystem/GlassStyle.swift` (deployment target stays
  iOS 16). The iOS CI job therefore needs the `macos-26` runner (iOS 26 SDK).
  See `docs/DESIGN.md`.

## Verification

| What | How |
|---|---|
| Swift packages | `swift test` inside each package (Linux OK; CI: core-linux.yml uses the `swift:6.0` container) |
| Jellyfin API layer, live | `scripts/dev-jellyfin/up.sh`, then in `ios/Packages/JellyfinBackend`: `JELLYFIN_TEST_URL=http://localhost:8096 JELLYFIN_TEST_USER=demo JELLYFIN_TEST_PASSWORD=demo swift test --filter JellyfinLiveTests` (skipped without the variables; in Docker add `--network host` and `-e`; CI: `jellyfin-live` in core-linux.yml). Findings: `docs/JELLYFIN-API-NOTES.md` |
| Server | `cd server && .venv/bin/pytest -q && .venv/bin/ruff check .` (setup: `python3 -m venv .venv && .venv/bin/pip install -e ".[dev]"`) |
| App target | macOS only: `xcodegen generate` + xcodebuild (CI: ios.yml on PRs) |
| App unit tests, UI tests, screenshots | macOS only, all in demo mode (no server): `docs/TESTING.md`. UI tests run in ios-ui-tests.yml — by hand, or put `[ui-tests]` in a commit message |

Notes for sandboxed environments: Docker Hub blob pulls and swift.org may be
blocked. The Google mirror usually works (start `dockerd` first if needed):
`docker run --rm -v $PWD:/w -w /w/ios/Packages/<Pkg> mirror.gcr.io/library/swift:6.0 swift test`
(same prefix for `jellyfin/jellyfin` and `library/python`). Otherwise rely on
the GitHub Actions workflows. The app target only compiles on macOS: `ios.yml`
runs on pushes to `claude/**` branches and on PRs.
A stale `server/data/jellyamp.sqlite` from older schema versions breaks
startup; delete it (it's gitignored, there are no migrations pre-1.0).

## Demo mode and UI tests

- `ios/Packages/JellyfinDemo` is a Jellyfin stand-in (fictional library,
  generated covers and audio, loopback HTTP server). The app signs in to it
  with "Try the Demo" or `-JellyampDemo YES`; UI tests and screenshots run
  against it. An API call a screen starts making must be answered by
  `DemoBackend` too — its tests run the real API clients against it.
- UI tests find elements by `AccessibilityID` (shared file
  `ios/Jellyamp/Support/AccessibilityID.swift`), never by label text.

## Gotchas already hit

- Jellyfin DTOs use PascalCase wire names; a property named `Type` must be
  written `` var `Type` `` (Swift keyword clash).
- Jellyfin omits `MediaSources`/`Genres` from `/Items` unless requested via
  `fields=`.
- Transcoded `/Audio/{id}/universal` streams are not byte-seekable — seek by
  re-requesting with `startTimeTicks`.
- `StreamingAudioSource` only schedules packets that arrive with packet
  descriptions (`handlePackets`), as MP3 and AAC do. Constant-bitrate PCM
  (WAV, AIFF) is parsed and then dropped, so such a file never starts —
  which is why the demo audio is AAC, not generated WAV.
- …but never put `startTimeTicks` on an HLS URL (`main.m3u8`): Jellyfin then
  answers every segment with 400. `StreamURLBuilder.url(_:seekingTo:)` knows.
- More measured server quirks (playlist move off by one, `ids=` lists hitting
  414, `+` decoded as space, play count taken at playback *start*, …) are in
  `docs/JELLYFIN-API-NOTES.md`; add to it and to `JellyfinLiveTests` when a
  new one turns up.
