# Jellyfin API Notes

What `JellyfinBackend` asks a Jellyfin server and what the server really
answers. Everything here was measured against **Jellyfin 10.10.7** holding the
synthetic library from `scripts/dev-jellyfin/` and is pinned by tests:

- `ios/Packages/JellyfinBackend/Tests/JellyfinLiveTests` — runs the whole API
  surface against a real server (how to run: [Live tests](#live-tests));
- `Tests/JellyfinBackendTests/ServerBehaviourTests.swift` — the same findings
  as canned-response regression tests, so they hold without a server.

The parameter and field names below are the ones in the server's own schema,
`GET /api-docs/openapi.json` — use that, not the web documentation, as ground
truth. Supported servers: **10.9 or newer** (lyrics, `/UserFavoriteItems`,
`/Items/Latest`, playlist update all arrived in 10.9); where an older route
is cheap to keep as a fallback, the code keeps it.

`JellyfinBackend` talks REST directly (`JellyfinSession.request`); it does not
use jellyfin-sdk-swift.

## Findings (what the code assumed vs. what the server does)

Each of these was a bug the live suite exposed; all are fixed.

| # | Assumed | Real server | Fix |
|---|---|---|---|
| 1 | Albums/playlists carry `ChildCount` | Only with `fields=ChildCount`; every album had `trackCount == nil` | `ChildCount` is in `defaultFields` |
| 2 | `/Artists/AlbumArtists` items carry `Genres` | Only with `fields=Genres` (the call sent no `fields`) | artist lists go through the common `fields=` |
| 3 | `/Items/Latest` returns full albums | No `Genres` without `fields=`; `ChildCount` is **0 for every album**, with or without `fields` | `fields=` sent; `ChildCount 0` maps to `trackCount == nil` |
| 4 | "Appears on" = `contributingArtistIds=X&excludeArtistIds=X` | That combination is **always empty** | `contributingArtistIds=X` alone (it already excludes the artist's own albums) |
| 5 | `/Items?ids=<id>` answers that item or nothing | An `ids` value that is not a GUID is dropped and the **unfiltered** query answered: the user's root folders "Music" and "Playlists". `artist(id:)` returned an artist called "Music" | answers are matched against the requested ID and item type |
| 6 | Tracks of an album = `parentId=<album>` | `parentId` is the *folder*; an unknown ID is **400** (not an empty list), and tracks in disc sub-folders are not children of the album | `albumIds=<album>&recursive=true`, sorted `ParentIndexNumber,IndexNumber,SortName` |
| 7 | Any number of comma-joined IDs fits in a URL | **414** between 200 IDs (6.6 kB, fine) and 400 IDs (13 kB) | `tracks(byIDs:)`, playlist add/remove batch 100 IDs per request; `createPlaylist` sends a JSON body |
| 8 | `URLQueryItem` encodes everything that needs encoding | A literal `+` reaches Jellyfin as a **space** (search "AC+DC" → "AC DC", playlist "A+B" → "A B") | `+` is sent as `%2B` |
| 9 | `POST /Playlists/{id}/Items/{entry}/Move/{n}` moves the entry to `n` | Off by one in both directions, see [Playlists](#playlists) | read back + corrective moves |
| 10 | Favorites via `/Users/{uid}/FavoriteItems/{id}` | Works, but is undocumented legacy since 10.9; the schema only has `/UserFavoriteItems/{id}?userId=` | new route, legacy as fallback on 404 |
| 11 | Instant mix returns `limit` distinct tracks | For a track seed: the seed first, then a mix that **contains the seed again**, `limit + 1` items | de-duplicated, cut to `limit` |
| 12 | `startTimeTicks` seeks a transcode URL | On the HLS URL the builder produces, every segment then fails with **400 "StartTimeTicks is not allowed"** | `url(_:seekingTo:)` leaves `.m3u8` URLs alone; `progressiveTranscodeURL` added for real `startTimeTicks` seeking |
| 13 | The search term can be sent as typed | `"power on "` (trailing space) finds nothing | term is trimmed; blank term → no request |
| 14 | 401 is reported as `.unauthorized` | True for reads only; writes, lyrics and instant mix threw `.serverError(status: 401)` | one status mapping for all calls, see [Errors](#errors) |
| 15 | One odd item cannot hurt | One item that does not decode failed the whole page | lists drop undecodable items (`LossyArray`) |
| 16 | `async let` for four parallel searches | When one fails the siblings are cancelled, and cancelling an in-flight request can hang URLSession on Linux (1 in 4 runs) | task group, every request runs to its end |

## Errors

All calls in the package map HTTP status the same way (`JellyfinError.init?(httpStatus:)`,
`JellyfinError.httpStatus` gives the code back):

| Status | Error | When the real server sends it |
|---|---|---|
| 401 | `.unauthorized` | token missing, expired or revoked — for **every** endpoint, including stream URLs (`api_key=`) |
| 404 | `.notFound` | unknown item/playlist (`/Items/{id}/Similar`, `/InstantMix`, `/Playlists/{id}/…`, `/UserFavoriteItems/{id}`, `DELETE /Items/{id}`) |
| other | `.serverError(status:)` | 400 malformed GUID in a path or unknown `parentId`; 414 URL too long; 500 from the playlist move (below). Not observed but to be expected: 403 when the user's policy forbids the action |
| — | `.invalidResponse` | 2xx whose body is not the expected JSON (captive portal, proxy error page) |

Session expiry should hook onto `.unauthorized` (equivalently `httpStatus == 401`).
A wrong password on `/Users/AuthenticateByName` is 401 as well. Not every miss
is an error: list queries with an unknown `albumIds`/`genreIds`/`artistIds`
answer 200 with no items; lyrics of a track without lyrics are 404 → `nil`.

Network failures are not `JellyfinError`s: they surface as the transport's
error (`URLError`). Metadata requests time out after 30 s, the image upload
after 120 s.

Signing in again with a `DeviceId` that is already signed in **revokes the
older token**. Two installs (or a test and the app) sharing a device ID log
each other out; `JellyfinSession.deviceID` must be unique per install.

## Library queries

- Albums: `GET /Items?includeItemTypes=MusicAlbum&recursive=true&sortBy=&sortOrder=&startIndex=&limit=`.
  The sorts the app sends all work: `SortName`, `DateCreated`,
  `ProductionYear`, `AlbumArtist,SortName` (comma = secondary key), `Random`
  (a new order per request — paging a random list repeats and skips items).
  An unknown `sortBy` value is **ignored, not rejected** (200, arbitrary order).
- `fields=` (`defaultFields`): `MediaSources,Genres,DateCreated,ParentId,Overview,ChildCount`.
  Without it there is no codec/bitrate/container, no genres and no track count.
  `enableTotalRecordCount=false` is sent on every list (nobody reads the count
  and it costs the server a second query).
- Artists: `GET /Artists/AlbumArtists` (the artist grid; includes "Various
  Artists"). `GET /Artists` lists *track* artists instead (no "Various
  Artists"). Sort name drops the article: "The Granite Saints" sorts under G —
  but only for artists; for `sortBy=AlbumArtist` on albums it sorts under T.
- One album/artist: `GET /Items?ids=<id>` with `userId` (so `UserData` is the
  user's). The artist `Overview` is `null` unless the server has metadata for
  the artist.
- Albums of an artist: `albumArtistIds=`; appears on: `contributingArtistIds=`;
  all tracks crediting an artist: `artistIds=`.
- Genres: `GET /MusicGenres` (marked deprecated in the schema, still the only
  one that works: `GET /Genres` returns nothing for a music library). Tracks of
  a genre: `genreIds=<id>`; `genres=` takes *names*, pipe-delimited.
- Recently added: `GET /Items/Latest?includeItemTypes=MusicAlbum` — a bare JSON
  array, not the `{Items: []}` envelope.
- Recently played: `sortBy=DatePlayed&sortOrder=Descending&filters=IsPlayed`.
- Top tracks: `artistIds=&sortBy=PlayCount,SortName&sortOrder=Descending`. With
  no plays at all this is simply name-descending.
- Similar: `GET /Items/{id}/Similar` works for artists, albums and tracks
  (`/Artists/{id}/Similar` and `/Albums/{id}/Similar` answer the same). It is
  genre overlap: in the test library the only artist "similar" to Neon Circuit
  is the compilation's "Various Artists".
- Search: `searchTerm=` matches the item **name only**, case- and
  diacritics-insensitive ("cafe" finds "Café"), as a substring. It does not
  find tracks by their artist's name; the artist is found as `MusicArtist`.
- Favorites: `filters=IsFavorite` on `/Items` (tracks, albums),
  `isFavorite=true` on `/Artists/AlbumArtists`. A favorited artist who is only
  ever a track artist is therefore not listed (not reproducible with the test
  library, which has no such artist).
- Item IDs are derived from the file path: the same library mounted at the
  same path has the same IDs on every server instance. Image tags are not
  stable across instances.

## Playlists

- Create: `POST /Playlists` with JSON body `{Name, Ids, UserId, MediaType: "Audio"}`.
- Items: `GET /Playlists/{id}/Items` — each with `PlaylistItemId` (the entry
  ID). On 10.10 the entry ID **equals the item ID**, and a playlist holds a
  track **at most once**: adding an ID that is already in it is silently
  ignored (so "add" can leave the count unchanged).
- Add: `POST /Playlists/{id}/Items?ids=` (query only, batched). Remove:
  `DELETE /Playlists/{id}/Items?entryIds=` (unknown entry IDs are ignored, 204).
- Rename: `POST /Playlists/{id}` with `{"Name": …}`. Cover:
  `POST /Items/{id}/Images/Primary`, `Content-Type: image/jpeg`, body =
  **base64 text** of the JPEG. Delete: `DELETE /Items/{id}` (second time: 404).
- A new playlist reports `RunTimeTicks: 0` and the duration lags behind
  changes; the app should sum track durations itself.

### Reordering

`POST /Playlists/{id}/Items/{entryId}/Move/{newIndex}` on 10.10.7, measured on
a five-entry playlist (row: old index, column: `newIndex`, cell: where the
entry ends up):

| old \ new | 0 | 1 | 2 | 3 | 4 | ≥5 |
|---|---|---|---|---|---|---|
| 0 | 0 | **2** | **3** | **4** | 4 | 500 |
| 1 | **1** | 1 | **3** | **4** | 4 | 500 |
| 2 | **1** | 1 | 2 | **4** | 4 | 500 |
| 3 | **1** | 1 | 2 | 3 | 4 | 500 |
| 4 | **1** | 1 | 2 | 3 | 4 | 500 |

Moving up lands at `max(newIndex, 1)` (nothing can be moved to the top),
moving down at `min(newIndex + 1, n - 1)` (one too low). An unknown entry is a
500 as well. Two moves are right on this server *and* on a correct one: moving
an entry up to an index ≥ 1, and moving the top entry away.
`movePlaylistItem(playlistID:entryID:toIndex:)` — `toIndex` is the entry's
final position — issues the natural move, reads the order back, and lets
`PlaylistReorder.nextMove` choose corrective moves from those two until the
order is right: one call on a correct server, at most three on 10.10.

Do **not** reorder by rewriting the playlist (`POST /Playlists/{id}` with
`{"Ids": [...]}`), tempting as it is: it does set the order, but it queues a
metadata refresh of the playlist, and whatever changes the playlist while that
refresh is in flight is **silently undone a moment later** — the next reorder,
a removal (the removed tracks come back), a rename. Measured window on a fast
machine: under 100 ms; it grows with the server's load. The code only uses it
as a last resort when moves do not converge.

## Loudness

`NormalizationGain` (dB to reach −18 LUFS; `float`, nullable) is on tracks
**and** albums and needs no `fields=`. It maps to `Track.normalizationGainDB`
and `Album.normalizationGainDB`. The server only fills it when

1. the library has *LUFS scan* enabled (`LibraryOptions.EnableLUFSScan`), and
2. the scheduled task **Audio Normalization** has run since. A normal library
   scan never measures anything, so a freshly added library has `null`
   everywhere even with the option on.

Via API (admin): read `GET /Library/VirtualFolders`, post the folder's options
back with `EnableLUFSScan: true` to `POST /Library/VirtualFolders/LibraryOptions`
(`{"Id": <ItemId>, "LibraryOptions": {…}}`), then start the task whose `Key` is
`AudioNormalization` from `GET /ScheduledTasks` with
`POST /ScheduledTasks/Running/{taskId}`. The task only measures items without a
value and changes nothing else (IDs, names, images stay). It must not overlap
the library scan: album gains written while the scan is still saving albums
are lost — run it again. `scripts/dev-jellyfin/up.sh` does all of this.

## Streaming

`StreamURLBuilder` URLs, fetched without an `Authorization` header (auth is
`api_key=` in the URL; without it: 401):

- **Direct play** `GET /Items/{id}/File`: the original bytes, `Accept-Ranges:
  bytes`, 206 with `Content-Range` for range requests, correct `Content-Type`
  for all four formats (`audio/mpeg`, `audio/flac`, `audio/mp4`, `audio/ogg`).
  There is a `Last-Modified` but **no `ETag`**, and **`HEAD` is 405**.
  `GET /Items/{id}/Download` serves the same bytes plus a `Content-Disposition`
  with the file name.
- **HLS transcode** `GET /Audio/{id}/main.m3u8?audioCodec=aac&audioBitRate=…`:
  a VOD playlist of the whole track in 3 s MPEG-TS segments (`video/mp2t`),
  whose segment URLs repeat the query (including `api_key`). Works from mp3,
  flac, m4a and ogg sources. Seeking is the player's job. **Never add
  `startTimeTicks`** (finding 12).
- **Progressive transcode** `GET /Audio/{id}/stream.{container}`
  (`StreamURLBuilder.progressiveTranscodeURL`): one response (`audio/aac` for
  `stream.aac`), not byte-seekable; `startTimeTicks` makes it start at that
  position (a request at 20 s of a 30 s track returns a third of the bytes).
  This is the URL for a player that reads a byte stream itself.
- A transcode keeps an ffmpeg job alive until the client reports
  `Sessions/Playing/Stopped` or calls
  `DELETE /Videos/ActiveEncodings?deviceId=&playSessionId=`.

## Images

`GET /Items/{id}/Images/Primary?fillWidth=&quality=90&tag=` needs no
authentication. `fillWidth` is honoured exactly (a 600 px cover asked for at
60 comes back 60 px wide). The `tag` is a cache key, not a selector: a wrong or
missing tag returns the same picture — but only **with** a tag does the server
send `Cache-Control: public, max-age=31536000` (without: no max-age), so always
pass the tag you have. Tracks have no image of their own in a folder-art
library (`ImageTags: {}`): use `AlbumId` + `AlbumPrimaryImageTag`
(`ImageURLBuilder.trackImageURL`). A missing image (artist without picture,
album without backdrop) is 404.

## Smart features (the fallback sonic provider)

- `GET /Items/{id}/InstantMix?limit=` — seeds: track, album, artist, music
  genre (playlist seeds are in the schema, untested). Genre driven: the mix of anything Electronic is the
  Electronic tracks. A track seed leads its own mix (and see finding 11).
  Unknown seed: 404.
- `GET /Items/{id}/Similar?limit=` — items of the seed's kind, never the seed.
- Stations: `GET /Items?includeItemTypes=Audio&recursive=true&sortBy=Random`
  with `genres=<name>` and/or `years=1990,1991,…` (a comma list; there is no
  range parameter). An unknown genre is an empty list, not an error.

## Lyrics

`GET /Audio/{id}/Lyrics` → `{"Metadata": {…}, "Lyrics": [{"Text", "Start"}]}`,
`Start` in ticks (100 ns), absent for unsynced lyrics. A sidecar `.lrc` next to
the track is picked up by the library scan (`HasLyrics: true` on the item).
No lyrics and unknown item are both 404 → `nil`.

## Playback reporting (observed; owned by the player slice)

`POST /Sessions/Playing`, `/Sessions/Playing/Progress`, `/Sessions/Playing/Stopped`
with `{ItemId, PositionTicks, IsPaused, PlayMethod, PlaySessionId, CanSeek}`
all answer 204. For audio the **start** report already counts the play:
`PlayCount` +1, `Played: true`, `LastPlayedDate` set — stopping after 10 of 30
seconds or at the end changes nothing further, and `PlaybackPositionTicks`
stays 0 (no resume position for music). A skipped track therefore counts as
played; `DELETE /UserPlayedItems/{id}` resets the count to 0.

## Onboarding (observed; owned by the auth slice)

- `GET /System/Info/Public` (no auth): `ServerName`, `Version`, `Id`,
  `StartupWizardCompleted`. `GET /System/Ping` → 200. `GET /System/Info` → 401
  without a token.
- Quick Connect: `GET /QuickConnect/Enabled` → `true` by default;
  `POST /QuickConnect/Initiate` (GET is 400) → `{Secret, Code}`;
  `GET /QuickConnect/Connect?secret=`; `POST /Users/AuthenticateWithQuickConnect`.
- `GET /Users/Public` is an empty list unless users are un-hidden.
- `POST /Sessions/Logout` invalidates the token.

## Live tests

```sh
scripts/dev-jellyfin/up.sh        # Jellyfin 10.10.7 + library + user demo/demo on :8096
cd ios/Packages/JellyfinBackend
JELLYFIN_TEST_URL=http://localhost:8096 JELLYFIN_TEST_USER=demo JELLYFIN_TEST_PASSWORD=demo \
  swift test --filter JellyfinLiveTests
# or in the Swift container:
docker run --rm --network host -v "$PWD/../../..":/w -w /w/ios/Packages/JellyfinBackend \
  -e JELLYFIN_TEST_URL=http://localhost:8096 -e JELLYFIN_TEST_USER=demo -e JELLYFIN_TEST_PASSWORD=demo \
  swift:6.0 swift test --filter JellyfinLiveTests
```

Without the three variables every live test is skipped. The suite expects the
library `scripts/dev-jellyfin/make-library.py` generates (`Library` in
`LiveSupport.swift` mirrors its `ALBUMS` table — change both together) with
the loudness scan done. It creates only what it deletes again and can share a
server with other clients. CI runs it in `core-linux.yml` (`jellyfin-live`).
