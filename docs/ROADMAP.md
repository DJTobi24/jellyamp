# Status and roadmap

Jellyamp 1.0.0 is feature-complete and prepared for App Store submission. It
is **not published yet**: the remaining steps need the Apple Developer
account holder (see [RELEASE.md](RELEASE.md)) and a pass on a real device.

This page records what the original five-phase plan promised, what 1.0
contains, what it does not, and what comes next. ✅ means the code exists and
is covered by the checks in [ARCHITECTURE.md](ARCHITECTURE.md#testing-strategy);
it does not mean "verified by ear on a device".

## What shipped in 1.0

### Phase 0 — Foundation

- ✅ Monorepo, docs, ADRs, CI workflows
- ✅ `JellyampCore`, `JellyfinBackend`, `SonicClient` with unit tests on Linux
- ✅ `ios/project.yml`, generated Xcode project
- ✅ `server/`: FastAPI app, store, sonic math, contract tests, Dockerfile

### Phase 1 — Core player

- ✅ Onboarding: server address, password sign-in, Quick Connect; session
  expiry handling
- ✅ Library: artists, albums, songs, genres, playlists (create, rename,
  reorder, delete, cover), recently added and played, liked songs, saved
  albums, followed artists; sorting, filtering, paging
- ✅ Search (server-side, ranked and grouped in the app)
- ✅ Audio engine on `AVAudioEngine`: crossfade ("sweet fades": none inside an
  album), 10-band EQ with built-in presets, loudness leveling from
  `NormalizationGain` tags
- 🟡 Gapless: **near-gapless, not sample-accurate**. Album tracks are joined
  end to start without a fade, with a short gap while the next source opens
  ([AUDIO-ENGINE.md](AUDIO-ENGINE.md#not-yet))
- ✅ Now Playing: large artwork, blurred background, queue with history, mini
  player, quality badge
- ✅ Playback reporting to Jellyfin (play counts, last played)
- ❌ Ratings — only favorites exist
- ❌ Local full-text search (FTS5) and the GRDB metadata store — dropped, see
  [ADR-0005](adr/0005-json-files-instead-of-a-database.md)

### Phase 2 — System integration and offline

- ✅ Lock screen and Control Center, interruptions, route changes, AirPlay
  route picker
- ✅ Sleep timer (timed with fade-out, or end of track)
- ✅ Instant Mix and radio from any track, autoplay at the end of the queue
- ✅ Siri, Shortcuts and Spotlight through App Intents (not a SiriKit
  `INPlayMediaIntent` extension)
- 🟡 CarPlay: **code-complete, switched off**. It is compiled into every
  build and enabled with `CARPLAY_ENABLED=YES` once Apple has granted the
  CarPlay audio entitlement ([CARPLAY.md](CARPLAY.md))
- ✅ Background downloads of albums, playlists, artists and songs; Downloads
  tab; offline mode with an offline library; smart sync (favorite songs,
  favorite albums, newest mixes, storage limit)
- ✅ Synced lyrics

### Phase 3 — Companion server and sonic features

- ✅ `jellyamp-server` 1.0: incremental library scan, similarity, Sonic
  Adventure, weekly mixes, stations, loudness, REST API 1.1
  ([SONIC-API.md](SONIC-API.md))
- 🟡 Analysis: the default backend is the built-in **DSP** analyzer (ffmpeg +
  numpy, amd64 and arm64). Essentia/MusiCNN embeddings are an optional
  backend in a separate, larger, amd64-only image. The planned sqlite-vec
  index was replaced by an in-memory index
  ([ADR-0004](adr/0004-fastapi-essentia-backend.md))
- ✅ App: sonic server settings with connection test and analysis progress,
  Sonic Adventure, Mixes for You, similar albums on the album page
- ✅ Stations on Home: Library Radio, artist radio, genre stations, decade
  "Time Travel", track radio — sonically ranked with the server, random or
  Instant Mix without it
- ❌ Mood and style stations in the app (the API and client support them)

### Phase 4 — Polish and extras

- ✅ Visualizer (FFT bars and waveform, tinted from the artwork)
- ✅ Silence compression (opt-in)
- ✅ Loudness fallback for untagged tracks from the sonic server
- ✅ Last.fm and ListenBrainz scrobbling with an offline queue
  ([SCROBBLING.md](SCROBBLING.md)); Last.fm needs API keys at build time
- ✅ Sonic Sage (playlists from a text prompt): Home entry when the server
  has an Anthropic API key configured; not yet tried against the live API
- ✅ Smart sync of weekly mixes
- ✅ iPad layout (sidebar, multitasking, keyboard shortcuts), accessibility
  labels and Reduce Motion support
- ✅ App Store preparation: icon, privacy manifest, listing texts (English,
  German), fastlane lanes, release CI, privacy and support pages

## Known limitations

Playback ([AUDIO-ENGINE.md](AUDIO-ENGINE.md#not-yet)):

- No sample-accurate gapless playback.
- Seeking in direct-played MP4/M4A (and possibly FLAC) files can fail; the
  track then keeps playing at the old position.
- A network drop in the middle of a track ends the track.
- AirPlay uses normal session routing, not AirPlay 2 buffered playback.
- No custom EQ presets.
- Jellyfin counts a play when a track starts, so a skipped track counts as
  played ([JELLYFIN-API-NOTES.md](JELLYFIN-API-NOTES.md)).

Library and offline:

- Search finds items by their own name only; a track is not found by its
  artist's name (Jellyfin behaviour).
- While offline, favorites and playlists cannot be changed; changes are not
  queued.
- Offline browsing covers downloaded music only.
- The sonic "similar tracks" and "similar artists" sections exist as views
  but are not placed on a screen; the artist page uses Jellyfin's
  metadata-based similar artists.

App and platform:

- The UI is in English and German (738 strings, catalog written by hand and
  checked by `scripts/check-localization.py`); the German has not been read
  on a device yet. Siri phrases use a legacy `.strings` table.
- Dark appearance only.
- CarPlay is off until Apple grants the entitlement; it has only been
  exercised through its unit-tested list builder, never on a head unit.
- Self-signed HTTPS certificates are rejected.
- No widgets, no Live Activities, no Apple Watch app.
- App unit tests and UI tests run in the built-in demo mode on CI
  simulators ([TESTING.md](TESTING.md)); nothing has been heard on a device.

Companion server:

- DSP similarity captures timbre, brightness and pulse, not genre conventions
  or mood; distances are relative to the library.
- Loudness is measured over a 90-second clip unless
  `ANALYSIS_CLIP_SECONDS=0`.
- The API key is the only authentication; HTTPS needs a reverse proxy.

Release:

- Not on TestFlight or the App Store yet. The TestFlight workflow has never
  run (it needs the account's secrets).
- App Store screenshots are produced by the UI-test workflow (English and
  German, iPhone and iPad) as CI artifacts; they are not committed and need
  a visual check before upload.

## After 1.0

Roughly in order of value:

1. Device verification of the audio engine, then sample-accurate gapless
   (`GaplessPlan` and `SilenceTrimmer` in Core are the prepared pieces).
2. German proof-reading on a device.
3. CarPlay: request the entitlement, test on a head unit, switch it on.
4. Mood and style stations; similar tracks and sonic
   similar artists on their screens.
5. Reliable seeking in MP4/FLAC direct play; resume after a network drop.
6. Custom EQ presets.
7. Wider app-level test coverage (offline mode, CarPlay, intents).
8. An offline operation queue (favorites, playlist edits).
9. Ratings, widgets, Live Activities.
