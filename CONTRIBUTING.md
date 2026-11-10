# Contributing to Jellyamp

Jellyamp is a spare-time open-source project. Bug reports and pull requests
are welcome. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first; it
explains where things live. Known gaps are listed in
[docs/ROADMAP.md](docs/ROADMAP.md).

## Setup

| For | You need |
|---|---|
| Swift packages, server, scripts | Linux or macOS, Docker, Python 3.11+, `ffmpeg` |
| The app itself | a Mac with Xcode 26 and `brew install xcodegen` |

```sh
# App (macOS). The Xcode project is generated; never commit it.
cd ios
cp Config/Signing.xcconfig.example Config/Signing.xcconfig   # optional: Team ID, Last.fm keys
xcodegen generate
open Jellyamp.xcodeproj

# Server
cd server
python3 -m venv .venv && .venv/bin/pip install -e ".[dev]"
```

Re-run `xcodegen generate` after changing `ios/project.yml`, after adding or
removing source files, and after editing `Signing.xcconfig`.

A throwaway Jellyfin 10.10.7 with a synthetic, copyright-free library (34
tracks, cover art, lyrics, user `demo` / `demo`) for tests and screenshots:

```sh
scripts/dev-jellyfin/up.sh           # start on :8096 (idempotent); needs Docker and ffmpeg
scripts/dev-jellyfin/up.sh --down    # stop and delete its state
```

## Test layers

Run what your change touches; CI runs all of it except the engine
simulation.

| Layer | Command | Notes |
|---|---|---|
| Swift packages | `make test-core` | Runs `swift test` for the three packages in the `swift:6.0` container. If Docker Hub is blocked: `make test-core SWIFT_IMAGE=mirror.gcr.io/library/swift:6.0`. On a Mac, `swift test` inside a package works too |
| Jellyfin API, live | see below | Needs the dev Jellyfin; every live test skips itself without the variables |
| Audio engine control flow | `scripts/engine-sim/run.sh` | Compiles the real `AudioEnginePlayer` against fake audio nodes and plays scenarios; about a minute. Proves the state machine, not the sound |
| Server | `cd server && .venv/bin/pytest -q && .venv/bin/ruff check .` | DSP tests are skipped without `ffmpeg` on PATH. End-to-end: `JELLYFIN_URL=… JELLYFIN_API_KEY=… .venv/bin/pytest -m integration -s` |
| Sonic fixtures | `bash scripts/sync-fixtures.sh --check` | |
| Release configuration | `python3 scripts/check-appstore-metadata.py` | Listing texts, icon, privacy manifest, plist keys |
| App target | push the branch / open a PR | `ios.yml` builds, runs the (placeholder) app tests and makes an unsigned Release archive on a `macos-26` runner |

Live Jellyfin tests:

```sh
cd ios/Packages/JellyfinBackend
JELLYFIN_TEST_URL=http://localhost:8096 JELLYFIN_TEST_USER=demo JELLYFIN_TEST_PASSWORD=demo \
  swift test --filter JellyfinLiveTests
```

In the Swift container, from the repository root:

```sh
docker run --rm --network host \
  -e JELLYFIN_TEST_URL=http://localhost:8096 -e JELLYFIN_TEST_USER=demo -e JELLYFIN_TEST_PASSWORD=demo \
  -v "$PWD":/w -w /w/ios/Packages/JellyfinBackend swift:6.0 swift test --filter JellyfinLiveTests
```

If a build fails with "PCH was compiled with module cache path …", the
package was last built under a different mount path (`make` uses `/work`, the
line above `/w`): delete `ios/Packages/*/.build`.

Anything you can hear — decoding, fades, AirPlay, interruptions — and
background downloads and CarPlay need a real device. Say in the pull request
what you tested by hand.

## Code conventions

- **Keep the app shell thin.** If a decision can be written without an Apple
  framework, it goes into `JellyampCore` (or `JellyfinBackend` /
  `SonicClient`) with unit tests. Packages must keep building on Linux: guard
  Apple-only imports with `#if canImport`, and import `FoundationNetworking`
  where `URLSession` is used.
- **App target:** iOS 16 deployment target, Swift 5.9 language mode. Gate
  newer APIs with `if #available`. iOS 26 APIs only through
  `DesignSystem/GlassStyle.swift`.
- **No third-party dependencies** in the app, no analytics, no tracking.
  Secrets go in the Keychain, not in `AppSettings` or UserDefaults.
- **New settings** go into `AppSettings` with a default value, a
  `decodeIfPresent` line and a test, so existing users keep their settings.
- **Jellyfin behaviour** is documented where it was measured: add a finding
  to [docs/JELLYFIN-API-NOTES.md](docs/JELLYFIN-API-NOTES.md) and pin it with
  a test in `JellyfinLiveTests` and a canned-response test.
- **Comments explain why**, not what. No TODO stubs or placeholder
  implementations; something that cannot be finished goes behind a documented
  switch (CarPlay is the example).
- **Formatting:** `.editorconfig` (4 spaces, LF, final newline),
  `.swift-format` and `.swiftlint.yml` (130-column lines, sorted imports)
  describe the Swift style; neither tool runs in CI, so match the surrounding
  code. Python is checked by `ruff` (100 columns) in CI.
- **Accessibility:** every icon-only button gets an `.accessibilityLabel`;
  respect Reduce Motion in new animations.
- Do not weaken or delete tests to make a change pass.

## Adding a user-facing string

The app's source language is English and strings are written in place:

```swift
Text("Liked Songs")                                  // in a view
Label("Download", systemImage: "arrow.down.circle")
String(localized: "No tracks were found for this station.")   // outside a view
```

There are no string keys or tables to maintain. On every build Xcode extracts
these literals into `ios/Jellyamp/Resources/Localizable.xcstrings`
(`SWIFT_EMIT_LOC_STRINGS` and `LOCALIZATION_PREFERS_STRING_CATALOGS` are set
in `project.yml`). To translate, open that catalog in Xcode, add the language
and fill in the values, then commit the catalog. It is currently empty: the
app ships in English only.

Two places need more than a literal:

- A `String` variable passed to `Text(_:)` is shown verbatim and is not
  extracted. Build such strings with `String(localized:)`.
- Code in the packages cannot use the app's catalog. Core returns data, and
  the app supplies the words — see `CarPlayStrings`, filled in
  `CarPlaySceneDelegate`.

App Store listing texts are separate files under
`ios/fastlane/metadata/{en-US,de-DE}/`; `check-appstore-metadata.py` enforces
their length limits.

## Changing the Sonic API contract

[docs/SONIC-API.md](docs/SONIC-API.md) is the contract between `SonicClient`
and `server/`. Within major version 1 only additive changes are allowed (new
endpoints, new optional response fields, new capability strings), because
older apps talk to newer servers and the other way round.

1. Describe the change in `docs/SONIC-API.md` and add a row to its version
   table.
2. Edit or add the JSON fixtures in `server/tests/fixtures/` — the canonical
   copies.
3. Run `scripts/sync-fixtures.sh` to mirror them into
   `ios/Packages/SonicClient/Tests/SonicClientTests/Fixtures/`. Commit both.
4. Server: update the models and `API_VERSION` in
   `server/jellyamp_server/main.py`, and the contract tests in
   `server/tests/`.
5. Client: update `SonicAPIClient` / `SonicProviding` and their tests. New
   fields must decode as optional; keep the `info_v1_0.json` fixture passing
   so a 1.0 server still works.
6. A new capability needs a decision for `JellyfinFallbackSonicProvider`:
   implement it with plain Jellyfin, or leave it out of its `capabilities` so
   the UI hides the feature.

`bash scripts/sync-fixtures.sh --check` must pass; CI runs it in both the
Swift and the server workflow.

## Commits and pull requests

- Subject in the imperative, about 70 characters at most, saying what changes
  for the reader: "Search: do not cancel sibling requests when one fails". An
  area prefix (`server:`, `CI:`, `dev-jellyfin:`) is used where it helps.
- The body explains **why**: what was wrong or missing, what was measured,
  what was considered. Look at `git log` for examples.
- One logical change per commit. Update the docs a change makes wrong in the
  same commit, and add a line to [CHANGELOG.md](CHANGELOG.md) under
  *Unreleased* for anything a user or self-hoster would notice.
- Pull requests go to `main`. The workflows that apply to the changed paths
  must be green.
- Never commit `Signing.xcconfig`, `*.p8`, API keys, or a generated
  `*.xcodeproj`.

## Releases

App releases are tagged `vX.Y.Z` (must match `MARKETING_VERSION` in
`ios/project.yml`) and go through [docs/RELEASE.md](docs/RELEASE.md). Server
images are published from tags `server-vX.Y.Z`
(`.github/workflows/server-image.yml`).

## License

By contributing you agree that your contribution is licensed under the
project's [MIT License](LICENSE).
