# Sonic API — jellyamp-server REST contract (v1)

This document is the **source of truth** for the interface between the iOS
app (`SonicClient`) and `jellyamp-server`. Both sides are tested against the
shared fixtures in `server/tests/fixtures/`; change the contract here first,
update the fixtures, then both implementations.

- Base path: `/api/v1`
- Auth: `X-Api-Key: <key>` header on every request (key configured on the
  server, entered in the app's Sonic Server settings). `401` on mismatch.
- All item/artist/album/user IDs are **Jellyfin item IDs** — the app resolves
  them to metadata through Jellyfin; the server stores no media metadata
  beyond what analysis needs.
- Errors: standard HTTP codes with body `{ "detail": "message" }`.
  `404` when an ID is unknown/unanalyzed, `409` when an endpoint's capability
  is disabled.

## GET /api/v1/info

Capability discovery; the app calls this to decide whether to use the server
and which UI affordances to show.

```json
{
  "version": "1.0",
  "jellyfinServerId": "f0c3…",
  "tracksTotal": 12500,
  "tracksAnalyzed": 12034,
  "capabilities": ["similar", "adventure", "mixes", "stations", "loudness"]
}
```

## GET /healthz

Unauthenticated liveness probe → `{ "status": "ok" }`.

## GET /api/v1/similar/tracks/{itemId}?limit=50&excludeSameAlbum=true

Nearest neighbours in embedding space. `distance` is cosine distance
(0 = identical), ascending.

```json
{ "items": [ { "itemId": "a1b2…", "distance": 0.12 } ] }
```

`/api/v1/similar/artists/{artistId}?limit=20` and
`/api/v1/similar/albums/{albumId}?limit=20` work the same, using the centroid
of the artist's/album's track embeddings; `items[].itemId` are artist/album
IDs respectively.

## GET /api/v1/adventure?from={itemId}&to={itemId}&steps=20

Sonic Adventure: interpolates `steps` waypoints between the two tracks'
embeddings and returns the nearest distinct track per waypoint (artists
deduplicated within a sliding window). `position` runs 0…steps+1 including
the endpoints.

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
plus sonically similar library tracks. Regenerated weekly, stable IDs within
a week.

```json
{
  "mixes": [
    {
      "id": "mix-2026-w24-1",
      "title": "Mix #1",
      "description": "Based on Slowdive, Ride and 4 more",
      "seedItemIds": ["a1…", "b2…"],
      "itemIds": ["c3…", "d4…"]
    }
  ]
}
```

## POST /api/v1/stations

```json
{ "type": "genre", "seed": "Shoegaze", "count": 100 }
```

`type` ∈ `genre | mood | decade | style`; `seed` is a genre/style name
(matched case-insensitively against track genre tags), a decade string
(`"1990s"`), or an item ID for mood (mood = neighbourhood around the seed
track's embedding). Genre/style/decade stations are sonically ranked within
the matching subset of analyzed tracks; `404` when no analyzed track matches
the seed. Response:

```json
{ "itemIds": ["a1…", "b2…"] }
```

## GET /api/v1/loudness/{itemId}

Computed EBU R128 values, the app's fallback when Jellyfin items carry no
`NormalizationGain`:

```json
{ "integratedLufs": -9.4, "truePeak": -0.3 }
```

## Versioning

Breaking changes bump the base path (`/api/v2`); `info.version` reports the
implementation version. The app requires major version 1.
