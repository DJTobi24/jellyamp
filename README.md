# Jellyamp

**A Plexamp-class music player for Jellyfin on iOS.**

Jellyamp brings the audiophile listening experience of Plexamp to self-hosted
[Jellyfin](https://jellyfin.org) servers: true gapless playback, sweet crossfades,
loudness leveling, EQ, offline downloads, CarPlay — and, with the optional
companion server, real *sonic* features such as Sonic Adventure, sonically
similar tracks, and weekly auto-mixes powered by audio-embedding analysis.

> Status: **Phase 0 — foundation.** Core logic, API adapters, app shell, and the
> companion-server skeleton exist; the first runnable build lands in Phase 1.
> See [docs/ROADMAP.md](docs/ROADMAP.md).

## Repository layout

| Path | What it is |
|---|---|
| `ios/` | The iOS app: XcodeGen manifest, app shell, and local Swift packages |
| `ios/Packages/JellyampCore` | Pure-Swift playback logic (queue, crossfade, loudness, gapless planning) — Linux-testable |
| `ios/Packages/JellyfinBackend` | Adapter on top of [jellyfin-sdk-swift](https://github.com/jellyfin/jellyfin-sdk-swift) |
| `ios/Packages/SonicClient` | Client for the optional companion server + Jellyfin-only fallback |
| `server/` | `jellyamp-server` — optional Docker companion that analyzes your library and serves sonic features |
| `docs/` | Architecture, audio-engine design, REST contracts, ADRs, roadmap |

## Architecture in one paragraph

The app talks to a plain Jellyfin server for everything: auth (password or
Quick Connect), library browsing, streaming via `/Audio/{id}/universal`,
Instant Mix, and playback reporting. Sonic features are accessed through the
`SonicProviding` protocol: if a `jellyamp-server` is configured and healthy, the
app uses it (true audio-embedding similarity); otherwise it transparently falls
back to Jellyfin's metadata-based Instant Mix/Similar endpoints and hides the
features the fallback can't provide. Details in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Building the iOS app (macOS)

The Xcode project is generated, not checked in:

```sh
brew install xcodegen
cd ios
xcodegen generate
open Jellyamp.xcodeproj
```

Requires Xcode 15+, deployment target iOS 16.

## Developing on Linux

The pure-Swift packages and the server are fully testable without a Mac:

```sh
make test-core      # swift test for JellyampCore, SonicClient, JellyfinBackend
make test-server    # pytest for jellyamp-server
make lint           # swift-format + ruff
make server-up      # run jellyamp-server via docker compose
```

## Running the companion server (optional)

```sh
cd server
cp .env.example .env   # set JELLYFIN_URL, JELLYFIN_API_KEY, SONIC_API_KEY
docker compose up -d
```

The server scans your Jellyfin music library, computes per-track audio
embeddings, and exposes the REST API described in
[docs/SONIC-API.md](docs/SONIC-API.md). The app auto-detects it via
`GET /api/v1/info`.

## License

MIT — see [LICENSE](LICENSE). The companion server depends on
[Essentia](https://essentia.upf.edu/) (AGPL-3.0); see
[docs/adr/0004-fastapi-essentia-backend.md](docs/adr/0004-fastapi-essentia-backend.md).
