# Jellyamp — agent notes

Plexamp-style iOS music player for Jellyfin, version 1.0.0 (feature-complete,
not yet published). Monorepo: `ios/` (SwiftUI app + local SPM packages),
`server/` (optional FastAPI sonic-analysis companion), `docs/`. Start with
`docs/ARCHITECTURE.md`; status and known limitations are in `docs/ROADMAP.md`.

## Ground rules

- **The app shell stays thin.** Logic that doesn't need Apple frameworks goes
  into `ios/Packages/{JellyampCore,JellyfinBackend,SonicClient}` with unit
  tests — those build and test on Linux and are the primary safety net. The
  app target (`ios/Jellyamp`) compiles only on macOS CI; `JellyampTests` is a
  placeholder.
- **No third-party dependencies in the app, no analytics, no tracking.** The
  App Store privacy label is "Data Not Collected". Persistence is JSON files,
  UserDefaults and the Keychain — there is no database (ADR-0005). Secrets go
  in the Keychain (`KeychainCredentialStore`), never in `AppSettings`.
- **`docs/SONIC-API.md` is the contract** between `SonicClient` and
  `server/` (currently 1.1; minor versions are additive). Canonical JSON
  fixtures live in `server/tests/fixtures/`; after editing them run
  `scripts/sync-fixtures.sh` (CI fails if copies drift).
- The companion server is **optional** for users. The app must work against a
  plain Jellyfin server via `JellyfinFallbackSonicProvider`; UI affordances
  follow `container.sonicCapabilities`.
- The Xcode project, `Info.plist` and `.entitlements` are generated
  (`cd ios && xcodegen generate`) and gitignored. App-target settings live in
  `ios/project.yml`; per-developer values in the untracked
  `ios/Config/Signing.xcconfig`. Bundle ID: `dev.djtobi.jellyamp`.
- Deployment target iOS 16, Swift 5.9 language mode, built with the iOS 26
  SDK (`macos-26` runner). Gate anything newer than iOS 16 with
  `if #available`. iOS 26 / Liquid Glass APIs are used only via the helpers
  in `ios/Jellyamp/DesignSystem/GlassStyle.swift` (`docs/DESIGN.md`).
- `AppSettings` decodes tolerantly: add a field as property default +
  `decodeIfPresent` line + test, so saved settings are never reset.
- User-facing text is English, as `Text("…")` literals or
  `String(localized: "…")`; every icon-only button gets an
  `.accessibilityLabel`.
- Do not touch the audio streaming/scheduling internals
  (`StreamingAudioSource`, `TrackSchedulerNode`, the crossfade state machine
  in `AudioEnginePlayer`) casually: they were tuned on a device and cannot be
  heard here. `docs/AUDIO-ENGINE.md` describes them.
- CarPlay is compiled always and enabled only by
  `CARPLAY_ENABLED=YES xcodegen generate` (`docs/CARPLAY.md`).

## Verification

| What | How |
|---|---|
| Swift packages | `swift test` inside each package, or `make test-core` (CI: `core-linux.yml`, `swift:6.0` container) |
| Jellyfin API layer, live | `scripts/dev-jellyfin/up.sh` (Docker, ffmpeg; Jellyfin 10.10.7 + synthetic library, user `demo`/`demo`, env in `/tmp/jellyamp-dev-jellyfin/env`), then in `ios/Packages/JellyfinBackend`: `JELLYFIN_TEST_URL=http://localhost:8096 JELLYFIN_TEST_USER=demo JELLYFIN_TEST_PASSWORD=demo swift test --filter JellyfinLiveTests` (skipped without the variables; in Docker add `--network host` and `-e`; CI: `jellyfin-live` in `core-linux.yml`) |
| Audio engine control flow | `scripts/engine-sim/run.sh` — compiles the real `AudioEnginePlayer` against fake audio nodes in Docker, about a minute; proves state-machine behaviour, not sound. Not in CI |
| Server | `cd server && .venv/bin/pytest -q && .venv/bin/ruff check .` (setup: `python3 -m venv .venv && .venv/bin/pip install -e ".[dev]"`). The DSP tests need `ffmpeg` on PATH and are skipped without it; the 13 `integration` tests need `JELLYFIN_URL` + `JELLYFIN_API_KEY` |
| Sonic fixtures | `bash scripts/sync-fixtures.sh --check` |
| Release config | `python3 scripts/check-appstore-metadata.py` (listing limits, icon, privacy manifest vs. APIs used, plist keys) |
| App target | macOS only: `xcodegen generate` + xcodebuild (CI: `ios.yml` on pushes to `claude/**` and PRs to `main`; build, test, unsigned Release archive) |

Notes for sandboxed environments: Docker Hub blob pulls and swift.org may be
blocked. The Google mirror usually works (start `dockerd` first if needed):
`docker run --rm -v $PWD:/w -w /w/ios/Packages/<Pkg> mirror.gcr.io/library/swift:6.0 swift test`
(same prefix for `jellyfin/jellyfin` and `library/python`;
`make test-core SWIFT_IMAGE=mirror.gcr.io/library/swift:6.0`). Reach a local
Jellyfin with `curl --noproxy '*'`. The server's SQLite file needs no care: a
database from another schema version is reset on startup.

## Gotchas already hit

Swift / build:

- Jellyfin DTOs use PascalCase wire names; a property named `Type` must be
  written `` var `Type` `` (Swift keyword clash).
- `AudioPlaybackIntent` is iOS 17+. Audio App Intents conform to
  `AudioStartingIntent` through the `JellyampAudioIntent` alias in
  `PlaybackIntents.swift`.
- All test files of a package share one module: a helper type declared in two
  test files (it happened twice with `ScriptedTransport`) is a redeclaration
  error. Give test helpers file-specific names or make them `private`.
- A package's `.build` directory remembers the path it was built under.
  `make test-core` mounts the repo at `/work`, the `docker run` line below at
  `/w`; switching between them fails with "PCH was compiled with module cache
  path …" until `ios/Packages/*/.build` is deleted.
- `async let` siblings are cancelled when one throws, and cancelling an
  in-flight request can hang URLSession on Linux. Parallel requests use a
  task group whose children return `Result`.
- Never add `NSAllowsLocalNetworking` (or the other `NSAllows…` sub-keys)
  next to `NSAllowsArbitraryLoads` in `project.yml`: iOS then ignores the
  latter and HTTP servers reached by host name stop working.
- A new required-reason API (UserDefaults, file timestamps, disk space,
  system uptime, …) must be declared in `PrivacyInfo.xcprivacy`;
  `check-appstore-metadata.py` flags undeclared ones.

Jellyfin (measured on 10.10.7; full list and tests in
`docs/JELLYFIN-API-NOTES.md` — add to it and to `JellyfinLiveTests` when a
new quirk turns up):

- `/Items` omits `MediaSources`, `Genres` and `ChildCount` unless requested
  via `fields=`; `/Items/Latest` reports `ChildCount` 0 regardless.
- `/Items?ids=<not a GUID>` drops the filter and answers the unfiltered query
  — always match answers against the requested ID.
- Album tracks are `albumIds=<id>&recursive=true`, not `parentId=` (that is
  the folder; unknown IDs are 400).
- Long `ids=` lists hit 414 somewhere between 200 and 400 IDs: batch by 100.
- A literal `+` in a query arrives as a space: send `%2B`.
- Playlist `Move/{newIndex}` is off by one in both directions; reorder with
  read-back and corrective moves (`PlaylistReorder`), never by rewriting the
  playlist's `Ids`.
- Instant Mix for a track returns the seed twice and `limit + 1` items.
- Transcoded streams are not byte-seekable — seek by re-requesting the
  progressive URL with `startTimeTicks`. Never put `startTimeTicks` on an HLS
  URL (`main.m3u8`): every segment then answers 400.
- Direct play (`/Items/{id}/File`) supports ranges but `HEAD` is 405 and
  there is no `ETag`.
- The play count is taken at playback *start*; music has no resume position.
- Signing in with a `DeviceId` that is already signed in revokes the older
  token — device IDs must be unique per install (and per test).
- `NormalizationGain` is only filled after the *Audio Normalization* task
  ran with LUFS scan enabled; a plain library scan measures nothing.
