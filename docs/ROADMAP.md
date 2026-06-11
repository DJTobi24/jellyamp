# Roadmap

Full Plexamp feature parity is the goal; it ships in phases so each phase ends
with something usable.

## Phase 0 — Foundation ✦ current

No Mac required. Exit criteria: `swift test` green on Linux for all three
packages; server skeleton passes pytest and `docker build`.

- Monorepo scaffolding, docs, ADRs, CI workflows
- `JellyampCore`: models, play queue (shuffle/repeat/history), radio feeder,
  crossfade/loudness/silence math, gapless planning, direct-vs-transcode
  decision, playback-report state machine, lyrics timeline, settings
- `JellyfinBackend`: session/auth wrapper, library/instant-mix/lyrics APIs,
  stream & image URL builders, playback reporting
- `SonicClient`: `SonicProviding` protocol, REST client, Jellyfin fallback,
  discovery — tested against shared fixtures
- `ios/project.yml` + app-shell sources (compile-verified in Phase 1)
- `server/`: FastAPI skeleton, store, sonic math (similarity/adventure/mixes
  on synthetic embeddings), API contract tests, Dockerfile

## Phase 1 — Core player (first macOS work)

Exit criteria: an album plays gaplessly end-to-end against a real Jellyfin
server.

- `xcodegen generate`, app builds and runs
- Onboarding: server URL, AuthenticateByName, Quick Connect
- Library: artists / albums / tracks / genres / playlists, recently
  added/played, favorites & ratings
- Search (server-side + local FTS5)
- `EnginePlayer`: gapless, sweet fades, EQ, loudness leveling from tags
- Now Playing: large art, blurred-art background, queue sheet, mini player
- Playback reporting (play counts/resume on the server)

## Phase 2 — System integration & offline

- Lock screen / Control Center (`MPNowPlayingInfoCenter`,
  `MPRemoteCommandCenter`), interruption & route handling
- AirPlay route support; CarPlay audio app (templates); Siri / Shortcuts
  (`INPlayMediaIntent`)
- Background downloads, Downloads UI, full offline mode, smart-sync rules
- Sleep timer, synced lyrics view
- Track / artist / album radio + Instant Mix via Jellyfin (fallback provider)

## Phase 3 — Companion backend & sonic features

- `jellyamp-server` v1: library scan, MusiCNN embeddings, sqlite-vec index,
  full REST API per docs/SONIC-API.md
- App: sonic server settings + discovery, sonically similar
  tracks/artists/albums everywhere, **Sonic Adventure**, **Mixes for You**
  shelf, Stations (genre/mood/decade/style), decades "time travel" radio

## Phase 4 — Polish & extras

- Visualizers (FFT, art-reactive), silence compression toggle
- Loudness fallback analysis; gain for untagged libraries via server
- Last.fm & ListenBrainz scrobbling
- Optional LLM playlist generation ("Sonic Sage"-style, user-provided key,
  proxied by the server)
- Smart sync of weekly mixes for offline
- iPad layout, accessibility pass, App Store preparation
