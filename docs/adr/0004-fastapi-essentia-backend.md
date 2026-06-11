# ADR-0004: Python + FastAPI + Essentia for jellyamp-server

## Status
Accepted

## Context
Jellyfin has no audio analysis; Plexamp-grade sonic features (similarity,
Sonic Adventure, auto-mixes) need per-track audio embeddings. Mature
pretrained music-embedding models (MusiCNN, EffNet-Discogs) ship with
Essentia's Python bindings; the MIR ecosystem is Python-first.

## Decision
`server/` is Python 3.11 + FastAPI + essentia-tensorflow, with SQLite +
sqlite-vec as the single-file embedding store, packaged as one Docker
container configured via env vars (`JELLYFIN_URL`, `JELLYFIN_API_KEY`,
`SONIC_API_KEY`). Pydantic response models double as the contract in
docs/SONIC-API.md; fixtures are shared with the iOS `SonicClientTests`.

## Consequences
- Single-container deployment next to Jellyfin; no extra databases.
- Essentia is AGPL-3.0: it is an optional, separately deployed network
  service, so the MIT iOS app is unaffected; the server directory documents
  the AGPL dependency. The extractor is pluggable so a permissively licensed
  ONNX/CLAP backend can replace Essentia later.
- Analysis throughput ~1–3 tracks/s on CPU; incremental scans make this a
  one-time cost per library.
