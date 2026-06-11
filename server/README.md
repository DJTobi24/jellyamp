# jellyamp-server

Optional, self-hosted companion service for the Jellyamp iOS app. It connects
to your Jellyfin server with an API key, analyzes your music library
(per-track audio embeddings + EBU R128 loudness), and serves the sonic
features Jellyfin doesn't have: sonically similar tracks/artists/albums,
**Sonic Adventure**, weekly **Mixes for You**, and mood stations.

The REST contract is documented in [docs/SONIC-API.md](../docs/SONIC-API.md).
The Jellyamp app auto-detects the server via `GET /api/v1/info`; without it,
the app falls back to Jellyfin's built-in Instant Mix.

## Run

```sh
cp .env.example .env    # set JELLYFIN_URL, JELLYFIN_API_KEY, SONIC_API_KEY
docker compose up -d
```

Then enter `http://<host>:8095` and your `SONIC_API_KEY` in the Jellyamp app
under *Settings → Sonic Server*.

Analysis runs incrementally in the background (~1–3 tracks/s on CPU); the
analyzed/total counts are visible in `GET /api/v1/info` and in the app.

## Development

```sh
python -m venv .venv && . .venv/bin/activate
pip install -e ".[dev]"     # light: API + sonic math, no audio analysis
pytest
ruff check .
```

The `analysis` extra (`pip install -e ".[analysis]"`) pulls
essentia-tensorflow for the actual audio embedding pipeline; everything else
— similarity, adventure, mixes math, API contract — works and is tested
without it.

## Licensing note

The optional analysis pipeline depends on [Essentia](https://essentia.upf.edu/)
(AGPL-3.0). See [ADR-0004](../docs/adr/0004-fastapi-essentia-backend.md).
