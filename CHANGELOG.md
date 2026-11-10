# Changelog

All notable changes to Jellyamp (the iOS app) and `jellyamp-server` are
recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/). App releases are tagged `vX.Y.Z`,
server images `server-vX.Y.Z`.

## [1.0.0] - Unreleased

First release. Everything since the early prototype on `main` (sign-in,
basic library, AVPlayer playback, lock screen, sleep timer, Instant Mix).
Not yet submitted to the App Store; see [docs/ROADMAP.md](docs/ROADMAP.md)
for known limitations.

### Added

**Playback**
- Audio engine on `AVAudioEngine` with progressive streaming: playback starts
  after the first packets instead of after a full download.
- Crossfade between tracks; consecutive album tracks are joined without a
  fade.
- 10-band equalizer with built-in presets and a live band graph.
- Loudness leveling from Jellyfin's `NormalizationGain`, with one gain per
  album run, a peak-safe boost, and measured loudness from the sonic server
  for untagged tracks.
- Optional silence compression.
- Progressive transcoding for codecs iOS cannot stream, with seeking by time;
  separate bitrate limits for Wi-Fi and cellular.
- Visualizer (bars or waveform) tinted from the artwork.
- Now Playing: quality badge, queue with history, queue editing, shuffle and
  repeat, synced lyrics, iPad layout.
- Autoplay: similar tracks are appended when the queue runs low.
- Playback reports to Jellyfin with one play session per play-through.

**Library**
- Paged, sortable and filterable lists for albums, artists and songs, with an
  alphabet jump bar.
- Genres, liked songs, saved albums, followed artists.
- Richer artist page (top tracks, discography, appears on, similar artists)
  and album page (discs, similar albums).
- Playlists: create, rename, reorder, remove tracks, set a cover, delete; add
  to playlist from any track.
- Search across artists, albums, songs and playlists with ranked, grouped
  results and recent searches.
- On-disk cache so lists and Home paint immediately on launch.
- Adaptive shell: tab bar on iPhone, sidebar on iPad, Split View and Slide
  Over, hardware-keyboard shortcuts.
- Toast banners for results and errors; "Go to Album / Artist" from anywhere.

**Home, stations and sonic features**
- Home with Mixes for You, recently added and recently played.
- Endless stations: Library Radio, artist radio, genre stations, decade
  "Time Travel", track radio. Sonically ranked with jellyamp-server, random
  or Instant Mix against plain Jellyfin.
- Sonic Adventure: a path from one track to another, saved as a playlist if
  wanted.
- Sonic server settings with connection test and analysis progress.

**Offline**
- Background downloads of albums, playlists, artists and songs in original
  quality, with pause, resume and retry.
- Offline mode and an offline library: browse and search downloaded music
  when the server is unreachable; an offline banner shows the state.
- Smart sync: favorite songs, favorite albums and the newest mixes, with a
  storage limit; downloads over cellular are opt-in.

**Sign-in**
- Two-step onboarding with server check, password sign-in and Quick Connect.
- Session lifecycle: a token revoked on the server signs the app out with an
  explanation; an unreachable server does not.
- Account screen with server name, version and user.

**System integration**
- Siri, Shortcuts and Spotlight through App Intents: play music by name,
  shuffle liked songs, recently added, start radio, transport controls, like
  the current song, sleep timer.
- CarPlay audio app (Home, Library, Downloads, Now Playing), compiled into
  every build and switched on with `CARPLAY_ENABLED=YES` once Apple has
  granted the entitlement.

**Scrobbling**
- Last.fm and ListenBrainz scrobbling with now-playing updates and a
  persistent offline queue. Off by default; Last.fm needs API keys at build
  time.

**jellyamp-server 1.0 (Sonic API 1.1)**
- Incremental library scanner with retry limits and scan status.
- Pluggable analysis: a built-in DSP backend (ffmpeg + numpy, amd64 and
  arm64) as the default, Essentia/MusiCNN as an optional backend.
- Similar tracks, albums and artists; Sonic Adventure; weekly mixes that stay
  stable for the week; genre, decade, style and mood stations; EBU R128
  loudness.
- API 1.1: `info.analysis`, `info.scan`, `POST /scan`, `POST /sage` (Sonic
  Sage: playlists from a text prompt through the Anthropic API, off unless a
  key is configured), documented parameter ranges.
- Docker image that runs as non-root and refuses to start unconfigured with a
  readable error; workflow that publishes multi-arch images to GHCR.

**Project**
- App icon, privacy manifest, App Store listing texts in English and German,
  fastlane lanes, TestFlight workflow, release guide.
- Public privacy policy, support page and landing page (GitHub Pages).
- Dev Jellyfin rig with a synthetic library; live integration suite for the
  Jellyfin API layer; Linux simulation harness for the audio engine;
  metadata and release-configuration check.

### Changed

- The player is `AudioEnginePlayer`; the AVPlayer-based engine is gone.
- `JellyfinBackend` uses one client for requests, error mapping and decoding;
  HTTP 401 is reported as `unauthorized` for every call.
- Settings decode tolerantly, so new settings never reset saved ones.
- Bundle identifier is `dev.djtobi.jellyamp`.
- The app stays on the Jellyfin fallback until the sonic server has analyzed
  at least one track.
- Server: capabilities reflect the data that is available; the analysis
  default no longer requires Essentia; the sqlite-vec index was replaced by
  an in-memory index.

### Fixed

- Seeking started audio from the beginning while the clock showed the seek
  target.
- The first play after launch could stay silent; crossfade could skip
  straight to the next track.
- Jellyfin API behaviour found by the live suite: missing track counts and
  genres, "appears on" always empty, album tracks in disc folders, lookups
  answering with the wrong item for odd IDs, over-long ID lists (HTTP 414),
  `+` in search terms and playlist names, playlist reordering landing one
  position off, favorites on the current API route, Instant Mix duplicates,
  HLS URLs broken by `startTimeTicks`, search terms with trailing spaces, one
  undecodable item failing a whole page.
- Search no longer hangs when one of its parallel requests fails.
- Lyrics: odd lines are tolerated and an empty answer means "no lyrics".

### Removed

- GRDB dependency and the planned local metadata database
  ([ADR-0005](docs/adr/0005-json-files-instead-of-a-database.md)).
