# Jellyamp

**A Plexamp-style music player for your own Jellyfin server, on iPhone and iPad.**

> **Kurzüberblick (Deutsch):** Jellyamp ist ein Musikplayer für iPhone und
> iPad, der die Musik von deinem eigenen Jellyfin-Server abspielt – mit
> Crossfade, Equalizer, Lautstärkeangleichung, Offline-Downloads, Stationen
> und Scrobbling. Ein optionaler, selbst gehosteter Begleitserver
> (`server/`) ergänzt klangbasierte Funktionen wie „Sonic Adventure“ und
> wöchentliche Mixe. Version 1.0.0 ist fertig entwickelt, aber noch nicht im
> App Store oder auf TestFlight; die Schritte bis zur Veröffentlichung stehen
> in [docs/RELEASE.md](docs/RELEASE.md) (mit deutscher Kurzfassung).

Jellyamp plays the music library on a [Jellyfin](https://jellyfin.org) server
you run yourself. It is not a streaming service and comes with no music. The
goal is the listening experience of Plexamp for Jellyfin users: an
artwork-first player with crossfades, loudness leveling, an equalizer,
offline downloads and endless stations, plus sound-based features when you
add the optional companion server. Jellyamp is an independent open-source
project and is not affiliated with Jellyfin or Plex.

**Status:** 1.0.0, feature-complete, **not yet published** (no App Store or
TestFlight build). What works, what does not and what is next:
[docs/ROADMAP.md](docs/ROADMAP.md).

## Features

**Playback**
- Crossfade with a length you choose; tracks of one album are joined without
  a fade (near-gapless, not sample-accurate)
- 10-band equalizer with presets
- Loudness leveling from Jellyfin's normalization tags, per album where it
  matters
- Optional silence compression
- Plays original files where iOS can; otherwise the server transcodes.
  Separate bitrate limits for Wi-Fi and cellular
- Queue with history, shuffle, repeat, sleep timer, synced lyrics, visualizer

**Library**
- Artists, albums, songs, genres and playlists with sorting, filtering and
  fast paging
- Liked songs, saved albums, followed artists, recently added and played
- Search across artists, albums, songs and playlists
- Create, rename, reorder and delete playlists
- iPhone and iPad layouts (tab bar or sidebar, Split View, keyboard shortcuts)

**Offline**
- Download albums, playlists, artists or single songs in the background, in
  original quality
- Offline mode: browse and search what is downloaded when the server is
  unreachable
- Smart sync: keep favorites and the newest mixes on the device, with a
  storage limit

**Stations and sonic features**
- Instant Mix and radio from any track, autoplay when the queue ends
- Stations on Home: Library Radio, artist radio, genres, decades
- With the optional [companion server](#companion-server-optional): tracks
  and albums that *sound* alike, Sonic Adventure (a path from one track to
  another), weekly Mixes for You, and loudness for untagged files

**System integration**
- Lock screen and Control Center controls, AirPlay
- Siri, Shortcuts and Spotlight ("Play … in Jellyamp")
- CarPlay: built, but switched off until Apple grants the entitlement
  ([docs/CARPLAY.md](docs/CARPLAY.md))

**Scrobbling** (optional, off by default)
- Last.fm and ListenBrainz, with an offline queue
  ([docs/SCROBBLING.md](docs/SCROBBLING.md))

No analytics, no tracking, no third-party SDKs:
[privacy policy](docs/PRIVACY.md).

## Requirements

- iPhone or iPad with **iOS 16 or newer**
- **Jellyfin 10.9 or newer** with a music library, reachable from the device
- To build: a Mac with Xcode 26 (the app is built with the iOS 26 SDK)

## Screenshots

*Pending.* Screenshots will be added under `docs/screenshots/` (for example
`now-playing.png`, `library.png`, `home.png`, `downloads.png`,
`ipad-sidebar.png`). The directory does not exist yet.

## Quick start for users

There is no App Store or TestFlight build yet. Until there is, the only way
to use Jellyamp is to build it yourself (below). Help with connecting to a
server: [docs/SUPPORT.md](docs/SUPPORT.md).

## Quick start for developers

**Build the app (macOS).** The Xcode project is generated and not checked in.

```sh
brew install xcodegen
cd ios
cp Config/Signing.xcconfig.example Config/Signing.xcconfig   # optional: your Team ID, Last.fm keys
xcodegen generate
open Jellyamp.xcodeproj
```

Without `Signing.xcconfig` the app still builds for the simulator. Running on
a device needs your Team ID in that file. Details and the release process:
[docs/RELEASE.md](docs/RELEASE.md).

**Run the tests (Linux or macOS, needs Docker and Python 3.11+).** Most logic
lives in three Swift packages that build on Linux.

```sh
# Swift packages
make test-core SWIFT_IMAGE=mirror.gcr.io/library/swift:6.0   # or plain `make test-core` with Docker Hub

# Companion server
cd server
python3 -m venv .venv && .venv/bin/pip install -e ".[dev]"
.venv/bin/pytest -q && .venv/bin/ruff check .
cd ..

# Consistency checks
bash scripts/sync-fixtures.sh --check
python3 scripts/check-appstore-metadata.py
```

A throwaway Jellyfin with a synthetic library for integration tests, the
audio-engine simulation and all other test layers are described in
[CONTRIBUTING.md](CONTRIBUTING.md).

## Companion server (optional)

`jellyamp-server` runs next to Jellyfin in Docker, analyzes a short clip of
every track and serves similarity, Sonic Adventure, weekly mixes, stations and
loudness. The app works without it and falls back to Jellyfin's Instant Mix.

```sh
cd server
cp .env.example .env        # set JELLYFIN_URL, JELLYFIN_API_KEY, SONIC_API_KEY
docker compose up -d
```

Then enter `http://<host>:8095` and the key in the app under Settings → Sonic
Server. Full setup, configuration and troubleshooting:
[server/README.md](server/README.md).

## Repository layout

| Path | What it is |
|---|---|
| `ios/Jellyamp/` | The app: SwiftUI views and the adapters to Apple frameworks (audio engine, downloads, intents, CarPlay) |
| `ios/Packages/JellyampCore` | Platform-independent logic: queue, fades, loudness, downloads index, offline catalog, stations, scrobbling, settings |
| `ios/Packages/JellyfinBackend` | Jellyfin REST client, sign-in, stream URLs, offline library decorator |
| `ios/Packages/SonicClient` | Client for the companion server and the Jellyfin-only fallback |
| `ios/project.yml`, `ios/Config/` | XcodeGen manifest and build settings |
| `ios/fastlane/` | Release lanes and App Store listing texts |
| `server/` | `jellyamp-server` (Python, FastAPI) |
| `scripts/` | Dev Jellyfin rig, engine simulation, fixture sync, release checks, CI helpers |
| `docs/` | Documentation and the public pages (privacy, support) |

## Documentation

| Document | Content |
|---|---|
| [docs/ROADMAP.md](docs/ROADMAP.md) | Status of 1.0, known limitations, what is next |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Modules, dependency injection, data flows, persistence, testing |
| [docs/AUDIO-ENGINE.md](docs/AUDIO-ENGINE.md) | The audio engine as built |
| [docs/DESIGN.md](docs/DESIGN.md) | Look and feel, Liquid Glass on iOS 26 |
| [docs/JELLYFIN-API-NOTES.md](docs/JELLYFIN-API-NOTES.md) | What a real Jellyfin server does, measured |
| [docs/SONIC-API.md](docs/SONIC-API.md) | REST contract between the app and the companion server |
| [server/README.md](server/README.md) | Companion server setup and operation |
| [docs/SCROBBLING.md](docs/SCROBBLING.md) | Last.fm and ListenBrainz |
| [docs/CARPLAY.md](docs/CARPLAY.md) | CarPlay app, its build switch, the entitlement request |
| [docs/RELEASE.md](docs/RELEASE.md) | From zero to "Waiting for Review" |
| [docs/PRIVACY.md](docs/PRIVACY.md), [docs/SUPPORT.md](docs/SUPPORT.md) | Privacy policy and support page (also published via GitHub Pages) |
| [docs/adr/](docs/adr/) | Architecture decision records |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Setup, test layers, conventions |
| [CHANGELOG.md](CHANGELOG.md) | Release history |

## License

MIT — see [LICENSE](LICENSE). The app has no third-party dependencies. The
companion server's default image contains only permissively licensed
dependencies; its optional Essentia backend is AGPL-3.0 and lives in a
separate image ([ADR-0004](docs/adr/0004-fastapi-essentia-backend.md)).
