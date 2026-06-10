# Jellyfin API Notes

Endpoints Jellyamp uses, plus quirks discovered along the way. The official
SDK is [jellyfin-sdk-swift](https://github.com/jellyfin/jellyfin-sdk-swift);
`JellyfinBackend` wraps it and is the only module that imports it.

## Authentication

- `POST /Users/AuthenticateByName` — body `{ "Username", "Pw" }`, returns
  `AccessToken` + `User`. The SDK injects the `Authorization: MediaBrowser …`
  header on subsequent calls.
- **Quick Connect**: `GET /QuickConnect/Initiate` → code shown to the user →
  poll `GET /QuickConnect/Connect?secret=` until approved → exchange via
  `POST /Users/AuthenticateWithQuickConnect`. The SDK ships a `QuickConnect`
  helper.
- Device identity matters: send a stable `deviceId` so Jellyfin's device list
  and session reporting are sane.

## Library

- `GET /Items?includeItemTypes=MusicAlbum&recursive=true&sortBy=SortName` —
  albums; same with `Audio` for tracks, filter by `parentId` / `albumIds`.
- `GET /Artists` (album artists with `?isAlbumArtist=true`).
- `GET /Genres?includeItemTypes=Audio`.
- `GET /Playlists` items via `/Playlists/{id}/Items`.
- `GET /Items/Latest?includeItemTypes=Audio` — recently added.
- `GET /Items?sortBy=DatePlayed&sortOrder=Descending` — recently played.
- Favorites/ratings: `POST/DELETE /UserFavoriteItems/{id}`,
  `POST /UserItems/{id}/Rating`.
- **Fields**: request `fields=MediaSources,Genres,DateCreated,ParentId,Overview`
  explicitly — media-source info (codec, bitrate, container, size) is not
  included by default and `PlaybackProfile` needs it.
- `NormalizationGain` (track + album LUFS-based gain) is present on audio items
  since server 10.9 **if** the library has "enable LUFS scan" turned on.

## Streaming

- `GET /Audio/{id}/universal` — the one endpoint to rule them all. Key params:
  - `container=opus,mp3,aac,m4a,flac` + `audioCodec=` — what the client accepts;
  - `maxStreamingBitrate=` — cap (drives transcode decision server-side);
  - `static=true` ⇒ original file, supports HTTP byte ranges (seekable);
  - `startTimeTicks=` — server-side seek for transcoded streams (1 tick = 100 ns);
  - `deviceId`, `userId`, `api_key` (query auth works for URLs handed to
    players that can't set headers — we set headers where possible).
- Transcoded responses are chunked, **not** byte-range seekable; seeking means
  a new request with `startTimeTicks`.
- Watch out for Content-Type quirks on some containers (upstream issue
  jellyfin/jellyfin#15523) — don't trust the MIME type, trust the container we
  requested.

## Images

- `GET /Items/{id}/Images/Primary?fillWidth=&quality=90&tag=` — albums/artists.
  Use the `imageTags.Primary` value as `tag` for cache-busting. Tracks usually
  inherit `albumPrimaryImageTag` + `albumId`.
- Blurhash strings come with item DTOs → instant placeholder backgrounds.

## Smart features (built-in, used by the fallback provider)

- `GET /Items/{id}/InstantMix?limit=` — metadata-based mix from any seed
  (track/album/artist/genre/playlist).
- `GET /Items/{id}/Similar` — similar artists/albums (metadata only).
- Decade/genre stations without a backend: `GET /Items?years=` /
  `?genres=` + `sortBy=Random`.

## Playback reporting

- `POST /Sessions/Playing` (start), `POST /Sessions/Playing/Progress` (every
  ~10 s and on pause/seek), `POST /Sessions/Playing/Stopped`.
- Send `positionTicks` (100 ns units), `isPaused`, `playMethod`
  (`DirectStream`/`Transcode`), and a per-playback `playSessionId`.
- This drives play counts, "resume", and frees transcode jobs server-side —
  always send `Stopped`, even on skip.

## Lyrics

- `GET /Audio/{id}/Lyrics` (10.9+) — returns plain or synced lyrics
  (`Lyrics[]` with `Start` ticks when synced). `LyricsParser` in Core also
  handles embedded LRC text.
