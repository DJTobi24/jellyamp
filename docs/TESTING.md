# Testing

What is tested where, how to run it, and what CI runs when. The layers go
from fast and exact to slow and realistic; a change should be covered by the
lowest layer that can see it.

| # | Layer | Needs | Where | CI |
|---|---|---|---|---|
| 1 | Swift package tests | Linux or macOS | `ios/Packages/*/Tests` | every push (`core-linux.yml`) |
| 2 | Live Jellyfin suite | Docker | `ios/Packages/JellyfinBackend/Tests/JellyfinLiveTests` | every push (`core-linux.yml`, job `jellyfin-live`) |
| 3 | Companion server tests | Python 3.11 | `server/tests` | pushes touching `server/` (`server.yml`) |
| 4 | Audio engine simulation | Docker | `scripts/engine-sim` | by hand |
| 5 | App unit tests | macOS, simulator | `ios/JellyampTests` | pushes to `claude/**`, PRs (`ios.yml`) |
| 6 | UI tests | macOS, simulator | `ios/JellyampUITests` | by hand or `[ui-tests]` (`ios-ui-tests.yml`) |
| 7 | App Store screenshots | macOS, simulator | `ios/JellyampUITests/ScreenshotTests.swift` | with the UI tests |

Layers 5–7 need no server: they run the app in **demo mode** (below).

## 1. Swift package tests

All logic that does not need Apple frameworks lives in four local packages
and is tested with plain `swift test`, on Linux too:

```sh
cd ios/Packages/JellyampCore && swift test      # queue, paging, downloads, scrobbling, …
cd ios/Packages/JellyfinBackend && swift test   # Jellyfin REST clients against canned responses
cd ios/Packages/SonicClient && swift test       # Sonic API client against the shared fixtures
cd ios/Packages/JellyfinDemo && swift test      # the demo backend (see "Demo mode")
```

Without a Swift toolchain, use the container CI uses (from the repo root):

```sh
docker run --rm -v "$PWD":/w -w /w/ios/Packages/JellyampCore swift:6.0 swift test
```

The Sonic API fixtures are shared with the server (`server/tests/fixtures`);
`scripts/sync-fixtures.sh --check` fails when the copies drift.

## 2. Live Jellyfin suite

The same REST clients against a real Jellyfin 10.10.7 holding a synthetic
library — this is what found the server quirks in
[JELLYFIN-API-NOTES.md](JELLYFIN-API-NOTES.md):

```sh
scripts/dev-jellyfin/up.sh        # starts the server, user demo/demo, port 8096
cd ios/Packages/JellyfinBackend
JELLYFIN_TEST_URL=http://localhost:8096 JELLYFIN_TEST_USER=demo JELLYFIN_TEST_PASSWORD=demo \
  swift test --filter JellyfinLiveTests
scripts/dev-jellyfin/up.sh --down
```

Without the three variables every live test skips itself.

## 3. Companion server tests

```sh
cd server
python3 -m venv .venv && .venv/bin/pip install -e ".[dev]"
.venv/bin/pytest -q && .venv/bin/ruff check .
```

## 4. Audio engine simulation

`scripts/engine-sim/run.sh` compiles the real `AudioEnginePlayer` on Linux
against stub audio frameworks and plays scenarios through its state machine
(queue end, seeks, crossfades, failures, sleep timers, playback reports) in
about a minute. See [AUDIO-ENGINE.md](AUDIO-ENGINE.md). It proves control
flow, not sound.

## 5. App unit tests

`ios/JellyampTests` covers the app shell — what needs the Keychain,
`UserDefaults`, the sandbox or AVFoundation:

| File | What |
|---|---|
| `PersistenceTests.swift` | Keychain session round-trips (including blobs stored by older versions), settings store, `LibraryCache` scoping and size bound, `DownloadStore` paths and file extensions |
| `DemoModeTests.swift` | the container signs in to the demo backend without touching the Keychain; Home loads its shelves; sign-out leaves the demo; `PlayerStateModel` publishing |
| `DemoAudioTests.swift` | the system AAC decoder and the app's streaming decoder read the demo tracks; a playback smoke test (play, pause, seek, skip) |

```sh
cd ios && xcodegen generate
xcodebuild test -project Jellyamp.xcodeproj -scheme Jellyamp \
  -destination "platform=iOS Simulator,id=$(python3 ../scripts/ci/pick-simulator.py)"
# or: bundle exec fastlane test
```

The tests run inside the app on a simulator and put back whatever they
change (Keychain items, settings).

Audio hardware: the app builds its `AVAudioEngine` when it signs in, and that
needs an output device (a virtual one will do; GitHub's macOS runners have
one). On a Mac without any, the tests that sign the container in
(`DemoModeTests`) and the playback smoke test report themselves as
**skipped**; the smoke test also skips when the engine starts but does not
render. The two decoder tests in `DemoAudioTests` and everything in
`PersistenceTests` need no audio hardware and always run. A skip therefore
says something about the machine, not about the app — but check the test log
for skips before trusting a green run on a new runner image.

The app does not bootstrap itself while it hosts the unit tests
(`LaunchOptions.isHostingUnitTests`): the tests build their own
`DependencyContainer`s, and a sign-in or remembered demo mode on the
simulator must not run a second audio engine next to them.

On CI the simulator is booted before the build and the app is launched once
in demo mode before the tests (`scripts/ci/warm-up-simulator.sh`). On a
freshly booted simulator the first process that opens the audio output can
wait for the audio service until AudioToolbox aborts it ("RPC timeout" in
`AURemoteIO`); the warm-up takes that hit instead of the test host.

## 6. UI tests

`ios/JellyampUITests` drives the real app through its main journeys:
onboarding and the demo button, Home, album → play → mini player → Now
Playing (pause, next, queue, lyrics, favorite), every Library list, search,
creating / filling / deleting a playlist, downloading an album, every
Settings screen, sign-out, and the iPad sidebar layout.

```sh
cd ios && xcodegen generate
xcodebuild test -project Jellyamp.xcodeproj -scheme JellyampUITests \
  -destination "platform=iOS Simulator,id=$(python3 ../scripts/ci/pick-simulator.py)"
# iPad: … pick-simulator.py --family ipad
# one test: add  -only-testing:JellyampUITests/PlaybackUITests/testQueueAndLyrics
```

In Xcode: select the **JellyampUITests** scheme and press ⌘U. The UI tests
have their own scheme on purpose — they are not part of the `Jellyamp`
scheme's test action, so a UI flake cannot fail the unit-test gate. `ios.yml`
still *compiles* them on every push.

Rules the tests follow, and new ones should too:

- **Find elements by accessibility identifier, never by text.** The app is
  localized; labels change with the language. Identifiers live in
  `ios/Jellyamp/Support/AccessibilityID.swift`, which is compiled into both
  the app and the UI-test bundle. Add a constant there, attach it with
  `.accessibilityIdentifier(…)`, use it in the test. Identifiers that carry
  state (`nowPlaying.playPause.playing`, `collection.favorite.on`) let a test
  wait for a state without reading a localized value.
- Tab bar items cannot carry identifiers; they are addressed by position
  (`AccessibilityID.Tab`). System alerts and confirmation dialogs cannot
  either; those few buttons are matched by their English label, which is why
  the functional tests pin the app language to English.
- `tap(_:)` scrolls the element into view first: an element of a scroll view
  exists while it is off screen or under the tab bar, and a tap sent to its
  position would hit something else. Elements of *lazy* containers (`List`,
  lazy stacks) do not exist until they are near the screen — use
  `scrollToFind(_:)` for those. Since iOS 26 the tab bar shrinks to one icon
  while content is scrolled down; `open(_:)` / `openLibrary(_:)` expand it.
- Every wait has an explicit timeout (`waitFor(_:timeout:)`); no `sleep` to
  wait for the app. (Only the screenshot tests pause, so that covers have
  finished loading when the picture is taken.)
- Every test launches a fresh app (`launch()`), so tests are independent.
- Item IDs of the demo library are stable (`JellyampUITestCase.Demo`).

Launch arguments the app understands (for tests only; passed as `-Name YES`):

| Argument | Effect |
|---|---|
| `-JellyampDemo YES` | start signed in to the demo library |
| `-JellyampResetState YES` | default settings, no downloads, no caches; ignore a stored sign-in for this launch (the Keychain is not modified) |
| `-JellyampDisableAnimations YES` | no UIKit animations |

## 7. App Store screenshots

`ScreenshotTests` walks the demo library and captures eight screens (Home,
album, Now Playing, lyrics, library grid, search, artist, downloads). Each
screenshot is attached to the test result; a script exports the attachments
as PNGs. The demo library is made up and its covers are drawn in code, so
the screenshots contain nothing copyrighted.

```sh
cd ios
bundle exec fastlane screenshots                                  # iPhone 6.9" + iPad 13", en-US + de-DE
bundle exec fastlane screenshots devices:iphone languages:de-DE keep:true
# without fastlane, one device and language:
../scripts/ci/screenshots.sh ipad de-DE
```

Result: `ios/fastlane/screenshots/<language>/NN-name-<iphone|ipad>.png`,
where `bundle exec fastlane release` picks them up (it recognises the device
from the resolution). The simulators are chosen by
`scripts/ci/pick-simulator.py --screenshots`: the "Pro Max" iPhone and the
13-inch iPad Pro if installed, otherwise the nearest device — check the pixel
sizes against [RELEASE.md](RELEASE.md), step 10, before uploading. iPad
screenshots are landscape (the sidebar layout).

The language reaches the tests as `SCREENSHOT_LANGUAGE` (set
`TEST_RUNNER_SCREENSHOT_LANGUAGE` for `xcodebuild`). Screenshots are exported
with `scripts/ci/export-xcresult-attachments.py <bundle>.xcresult <dir>`,
which also saves the screenshots Xcode takes when a test fails
(`<dir>/other/`). It uses `xcresulttool export attachments` (Xcode 16+) and
falls back to the older object-graph commands.

fastlane's own `snapshot` is supported but not required: add its
`SnapshotHelper.swift` to `ios/JellyampUITests` (`bundle exec fastlane
snapshot init` generates it) and the `screenshots` lane switches to
`capture_screenshots` with `ios/fastlane/Snapfile`; the tests then call the
helper's `snapshot()` (compilation condition `FASTLANE_SNAPSHOT`).

## Demo mode

The app contains a sample library and a stand-in for the Jellyfin server
that serves it — package `ios/Packages/JellyfinDemo`:

- `DemoCatalog` — 6 artists, 12 albums, 60 tracks, 3 playlists, favorites,
  play history, lyrics, mixes. All names are fictional.
- `DemoBackend` — answers the Jellyfin REST calls the app makes (and the
  Sonic API, so Mixes for You and Sonic Adventure show up), with user data
  kept in memory: every launch starts from the same state.
- `DemoArtwork` — covers rendered in code and written as PNG.
- `DemoAudio` — tracks assembled from bundled four-second AAC loops
  (synthesized by `scripts/demo-audio/make.py`; nobody's recording).
- `DemoHTTPServer` — serves all of it on `http://127.0.0.1:<port>`.

In the app, `DemoMode` (`ios/Jellyamp/Support/Demo`) starts the server and
hands `DependencyContainer` a session for it. From there on the app does
what it does with any server: the REST clients, `AsyncImage`, the streaming
player and background downloads all talk HTTP to the loopback address. No
screen knows that demo mode exists, which is what makes UI tests against it
meaningful.

Ways in: the **Try the Demo** button on the sign-in screen (for App Review
and people without a server; remembered until sign-out) and the
`-JellyampDemo YES` launch argument (that launch only). Demo mode never
reads or writes the Keychain session, does not scrobble, and ends with
Settings → Account → Sign Out.

The package is tested on Linux by pointing the app's real API clients at it,
in process and over real sockets (`swift test` in `ios/Packages/JellyfinDemo`).
To look at the generated media:

```sh
cd ios/Packages/JellyfinDemo
DEMO_EXPORT_DIR=/tmp/demo swift test --filter testExportSamples   # covers as PNG, one track per genre
```

To change the audio loops, edit and run `scripts/demo-audio/make.py` (needs
numpy and ffmpeg) and commit the regenerated `Resources/Loops/*.aac`; all
loops must keep the same number of frames (`DemoAudio.framesPerLoop`, checked
by the tests).

## What CI runs when

| Workflow | Trigger | Runs |
|---|---|---|
| `core-linux.yml` | every push touching `ios/Packages` or `scripts`, PRs | package tests (four packages), live Jellyfin suite, fixture sync |
| `server.yml` | pushes and PRs touching `server/` | server lint + tests |
| `ios.yml` | pushes to `claude/**`, PRs to `main` | metadata check; simulator build; app unit tests; compiles the UI tests; unsigned Release archive |
| `ios-ui-tests.yml` | manually (Run workflow), or a push to `claude/**` whose commit message contains `[ui-tests]` | UI tests on an iPhone and an iPad simulator; screenshots in en-US and de-DE |

`ios-ui-tests.yml` always uploads three artifacts per device, also when
tests fail: `screenshots-<device>` (the PNGs, with failure screenshots under
`other/`), `ui-test-results-<device>` (the `.xcresult` bundles, open them in
Xcode) and `xcodebuild-logs-ui-<device>`.

When a test fails on CI, the job log is meant to be enough
(`scripts/ci/xcodebuild.sh` prints all of this at the end of the failed step):

- the failed tests with their messages, read from the result bundle;
- for UI tests, the accessibility hierarchy at the moment of the first failed
  assertion of each test (lines starting with `UI-HIERARCHY|`): which
  identifiers were on screen instead of the expected one;
- the crash reports written during the step
  (`scripts/ci/print-crash-reports.py`): exception, message and backtrace of
  an app that died — xcodebuild itself only says "Restarting after unexpected
  exit";
- the app's own log (`os.Logger`, subsystem `dev.djtobi.Jellyamp`), recorded
  from the simulator by `scripts/ci/app-log.sh` and printed by the step "App
  log of the failed test run": which track was loaded, whether the engine
  started, why a track was skipped.

A step whose tests passed ends with the counts of its result bundle
(total, passed, failed, skipped), so tests that skipped themselves are
visible in a green run too.

The artifacts hold the rest: failure screenshots (`screenshots-<device>`,
folder `other/`), the `.xcresult` bundles and the raw logs.

The "Audio output of the runner" step shows which audio devices the machine
has. Without any, the engine cannot start: the app then reports the track as
failed (it does not crash), and the playback tests fail on that.
