# Sonic API — jellyamp-server REST contract (v1)

This document is the **source of truth** for the interface between the iOS
app (`SonicClient`) and `jellyamp-server`. Both sides are tested against the
shared fixtures in `server/tests/fixtures/`; change the contract here first,
update the fixtures, then both implementations.

- Base path: `/api/v1`
- Auth: `X-Api-Key: <key>` header on every request (key configured on the
  server, entered in the app's Sonic Server settings). `401` on mismatch.
- All item/artist/album/user IDs are **Jellyfin item IDs** — the app resolves
  them to metadata through Jellyfin. The server caches only the minimal
  metadata its features need (title, artist name, album name, genres, year)
  and never returns it.
- Errors: standard HTTP codes with body `{ "detail": … }`.

  | Code  | Meaning                                                              |
  |-------|----------------------------------------------------------------------|
  | `401` | missing/wrong `X-Api-Key`                                            |
  | `404` | an ID is unknown or not analyzed (yet), or nothing matches a request |
  | `409` | the endpoint's capability is disabled on this server                 |
  | `422` | a parameter is missing or out of range (`detail` is a list)          |
  | `502` | an upstream service the endpoint depends on failed (Sonic Sage)      |

## Versioning and compatibility

`info.version` is `major.minor`. The app requires major version `1`.
**Minor versions are additive**: new endpoints, new *optional* response
fields, new capability strings. Clients must therefore ignore unknown JSON
fields and unknown capability strings, and must treat fields introduced in a
minor version as optional. Breaking changes bump the base path (`/api/v2`).

| Version | Changes                                                                          |
|---------|----------------------------------------------------------------------------------|
| 1.0     | initial contract                                                                 |
| 1.1     | `info.analysis`, `info.scan`; `POST /scan`; `POST /sage` and capability `sage`;   |
|         | capabilities reflect available data; documented parameter ranges (`422`)         |

## GET /api/v1/info

Capability discovery; the app calls this to decide whether to use the server
and which UI affordances to show. Cheap: served from cached state, safe to
poll every few seconds while a scan is running.

```json
{
  "version": "1.1",
  "jellyfinServerId": "f0c3…",
  "tracksTotal": 12500,
  "tracksAnalyzed": 12034,
  "capabilities": ["similar", "adventure", "mixes", "stations", "loudness", "sage"],
  "analysis": { "backend": "dsp", "version": "1" },
  "scan": {
    "state": "scanning",
    "startedAt": "2026-06-10T08:00:10Z",
    "finishedAt": null,
    "tracksPending": 463,
    "tracksFailed": 3,
    "lastError": null
  }
}
```

- `jellyfinServerId` — `""` while Jellyfin has never been reachable.
- `tracksTotal` — audio items in Jellyfin as of the last successful scan
  (never less than `tracksAnalyzed`).
- `tracksAnalyzed` — tracks with an embedding from the *active* analysis
  backend. After switching backends this drops to 0 and climbs again as the
  library is re-analyzed (embeddings of different backends are not comparable).
- `capabilities` — only what the server can answer **right now**:
  - `similar`, `adventure`, `mixes`, `stations`: at least one analyzed track.
  - `loudness`: at least one track has loudness data.
  - `sage`: an LLM key is configured on the server and tracks are analyzed.

  A freshly installed server reports `[]` until its first track is analyzed;
  use `scan` to show progress meanwhile.
- `analysis` *(1.1, optional)* — the active backend (`dsp`, `musicnn`), or
  `null` when the server cannot analyze (it then only serves stored data).
- `scan` *(1.1, optional)* — `null`/absent when the server has no Jellyfin
  connection. Otherwise:
  - `state`: `scanning` or `idle`.
  - `startedAt` / `finishedAt`: ISO-8601 UTC of the current or most recent
    scan; both `null` before the first scan, `finishedAt` `null` while one runs.
  - `tracksPending`: tracks the running scan still has to analyze (0 when idle).
  - `tracksFailed`: tracks the server has given up on after repeated failures
    (undecodable files). They are retried when the backend changes or via
    `POST /scan?retryFailed=true`.
  - `lastError`: why the most recent scan ended early (e.g. Jellyfin
    unreachable), `null` if it completed.

## POST /api/v1/scan *(1.1)*

Starts a library scan now instead of waiting for the next scheduled one
(scans run shortly after startup and then every `SCAN_INTERVAL_MINUTES`).
Returns immediately with `202`; poll `GET /info` for progress.

Query: `retryFailed=true` also retries tracks previously given up on.

```json
{ "started": true, "scan": { "state": "scanning", "startedAt": "…", "finishedAt": null,
                             "tracksPending": 0, "tracksFailed": 3, "lastError": null } }
```

`started` is `false` when a scan was already running (not an error).
`409` when the server has no Jellyfin connection.

## GET /healthz

Unauthenticated liveness probe → `{ "status": "ok" }`.

## GET /api/v1/similar/tracks/{itemId}?limit=50&excludeSameAlbum=true

Nearest neighbours in embedding space. `distance` is cosine distance
(0 = identical, up to 2), ascending. `limit` 1–500 (default 50).
`404` when the track is not analyzed.

```json
{ "items": [ { "itemId": "a1b2…", "distance": 0.12 } ] }
```

`/api/v1/similar/artists/{artistId}?limit=20` and
`/api/v1/similar/albums/{albumId}?limit=20` work the same, using the centroid
of the artist's/album's track embeddings; `items[].itemId` are artist/album
IDs respectively. A track counts towards its first track artist.

Distances are comparable within one response and one server, not across
servers or backends: the `dsp` backend measures similarity relative to the
library's own spread.

## GET /api/v1/adventure?from={itemId}&to={itemId}&steps=20

Sonic Adventure: interpolates `steps` waypoints between the two tracks'
embeddings and returns the nearest distinct track per waypoint (artists
deduplicated within a sliding window). `steps` 1–200 (default 20); `from`
and `to` must differ (`422`). `position` is dense, starting at 0, endpoints
included: `steps + 2` items, fewer when the library is too small to fill
every waypoint.

```json
{
  "items": [
    { "itemId": "fromId", "position": 0, "distance": 0.0 },
    { "itemId": "c3d4…",  "position": 1, "distance": 0.08 }
  ]
}
```

## GET /api/v1/mixes?userId={jellyfinUserId}

Weekly auto-mixes ("Mixes for You"): clusters of the user's recent listening
plus sonically similar library tracks. Generated on first request of an ISO
week and then **kept for that week** (same IDs, same tracks), so a mix the
user started on Monday is still there on Friday. Users without listening
history get mixes seeded from the library. `{"mixes": []}` when nothing is
analyzed.

```json
{
  "mixes": [
    {
      "id": "mix-2026-w24-1",
      "title": "Shoegaze Mix",
      "description": "Based on Slowdive, Ride and 4 more",
      "seedItemIds": ["a1…", "b2…"],
      "itemIds": ["c3…", "d4…"]
    }
  ]
}
```

`id` is `mix-{ISO year}-w{ISO week}-{n}`. `title` names the dominant genre of
the seeds or their lead artist (`"Mix #n"` when neither is known).

## POST /api/v1/stations

```json
{ "type": "genre", "seed": "Shoegaze", "count": 100 }
```

`type` ∈ `genre | mood | decade | style`; `count` 1–500 (default 100);
`seed` is a genre/style name (matched case-insensitively against track genre
tags), a decade string (`"1990s"`), or an item ID for mood (mood =
neighbourhood around the seed track's embedding). Genre/style/decade stations
are sonically ranked within the matching subset of analyzed tracks; `404`
when no analyzed track matches the seed. Stations are shuffled: two requests
return different orders. Response:

```json
{ "itemIds": ["a1…", "b2…"] }
```

## GET /api/v1/loudness/{itemId}

Measured EBU R128 values, the app's fallback when Jellyfin items carry no
`NormalizationGain`:

```json
{ "integratedLufs": -9.4, "truePeak": -0.3 }
```

`integratedLufs` in LUFS, `truePeak` in dBTP. Measured over the analyzed
clip (by default 90 s from the middle of the track), so it approximates the
whole-track value; servers configured with `ANALYSIS_CLIP_SECONDS=0` measure
entire tracks. `404` when the track is not analyzed or is silent.

## POST /api/v1/sage *(1.1, capability `sage`)*

Sonic Sage: a playlist from a natural-language request.

```json
{ "prompt": "hazy guitars for a rainy sunday", "count": 30 }
```

`prompt` 1–1000 characters; `count` 1–200 (default 30). Response:

```json
{
  "title": "Rainy Sunday Shoegaze",
  "description": "Hazy guitars from the early nineties for a slow afternoon.",
  "itemIds": ["a1…", "b2…"]
}
```

`itemIds` are analyzed library tracks in a sonically smooth order; there may
be fewer than `count`. Typical latency is several seconds.

- `409` — Sonic Sage is not enabled on this server (no LLM key) or nothing is
  analyzed yet.
- `404` — the request maps to nothing in this library.
- `502` — the language model could not be reached, refused, or failed.

**What leaves the server:** to interpret the prompt, the server sends the
prompt and a *summary* of the library (genre names, decades, and the most
common artist names with track counts) to the configured LLM provider
(Anthropic). Track titles, listening history, user IDs and audio never leave
the server. The model returns only search criteria; the server picks the
tracks. Prompts are not logged.
