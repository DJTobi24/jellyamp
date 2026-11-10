# jellyamp-server

Optional, self-hosted companion for the [Jellyamp](../README.md) iOS app. It
connects to your Jellyfin server, listens to your music library (a short clip
per track) and serves the "sonic" features Jellyfin does not have:

- **Sonically similar** tracks, albums and artists
- **Sonic Adventure** — a listening path that morphs from one track to another
- **Mixes for You** — weekly mixes built around what you have been playing
- **Stations** by genre, decade or mood
- **Loudness** (EBU R128) for volume levelling of untagged tracks
- **Sonic Sage** *(optional)* — playlists from a text prompt, using Claude

Without it the app still works and falls back to Jellyfin's Instant Mix. The
REST contract is in [docs/SONIC-API.md](../docs/SONIC-API.md).

## Setup in five minutes

You need Docker and a running Jellyfin.

**1. Create a Jellyfin API key.** In Jellyfin's web UI: *Dashboard → API Keys
→ **+*** — name it `jellyamp`, copy the key. (The server only reads: it lists
audio items and play history and streams clips.)

**2. Configure.**

```sh
cd server
cp .env.example .env
openssl rand -hex 32        # → use as SONIC_API_KEY
$EDITOR .env                # set JELLYFIN_URL, JELLYFIN_API_KEY, SONIC_API_KEY
```

`JELLYFIN_URL` must be reachable *from inside the container*:
`http://host.docker.internal:8096` if Jellyfin runs on the same machine,
`http://jellyfin:8096` if it is a service in the same compose project,
otherwise its LAN address.

**3. Start.**

```sh
docker compose up -d
docker compose logs -f      # watch the first scan
```

The first scan starts a few seconds after startup; expect roughly one to
three tracks per second (a 10 000-track library takes a couple of hours,
once). Later scans only look at new tracks.

**4. Check.**

```sh
curl -H "X-Api-Key: $SONIC_API_KEY" http://localhost:8095/api/v1/info
```

`tracksAnalyzed` climbs towards `tracksTotal`; features appear in
`capabilities` as soon as the first tracks are analyzed.

**5. Connect the app.** In Jellyamp: *Settings → Sonic Server* — enter
`http://<host>:8095` and your `SONIC_API_KEY`. The app shows the analysis
progress and enables the sonic features.

> The app talks to this server directly, so it must be reachable from your
> phone (same network or VPN). If you expose it to the internet, put it
> behind your HTTPS reverse proxy like Jellyfin itself; the API key is the
> only authentication.

## Configuration

All settings are environment variables (see [.env.example](.env.example)).

| Variable | Default | |
|---|---|---|
| `JELLYFIN_URL` | — | **Required.** Jellyfin base URL as seen from the container. |
| `JELLYFIN_API_KEY` | — | **Required.** Jellyfin API key. |
| `SONIC_API_KEY` | — | **Required.** Key the app must send (16+ characters). |
| `ANTHROPIC_API_KEY` | *(empty)* | Enables Sonic Sage. |
| `SAGE_MODEL` | `claude-opus-5-5` | Claude model used by Sonic Sage. |
| `ANALYSIS_BACKEND` | `auto` | `auto`, `dsp`, `essentia` or `none`. |
| `ANALYSIS_CLIP_SECONDS` | `90` | Audio analyzed per track (from the middle). `0` = whole track. |
| `ANALYSIS_CONCURRENCY` | `2` | Tracks analyzed in parallel. |
| `ANALYSIS_MAX_ATTEMPTS` | `3` | Failed attempts before a track is skipped. |
| `SCAN_INTERVAL_MINUTES` | `60` | Time between library scans. |
| `SCAN_STARTUP_DELAY_SECONDS` | `10` | Delay before the first scan. |
| `DATABASE_PATH` | `/data/jellyamp.sqlite` | SQLite file (in the image; `data/jellyamp.sqlite` otherwise). |
| `MUSICNN_MODEL_PATH` | `/models/msd-musicnn-1.pb` | Model file for the `essentia` backend. |
| `LOG_LEVEL` | `INFO` | |

The server refuses to start with a clear message (exit code 78) when a
required variable is missing.

The database holds only derived data — embeddings, loudness, and the titles,
artist names and genres needed for mix descriptions — and can be deleted at
any time; the next scan rebuilds it.

## Analysis backends

| | `dsp` (default) | `essentia` |
|---|---|---|
| Needs | `ffmpeg` (in the image) | the *full* image + MusiCNN model |
| Image | small, amd64 + arm64 | large (TensorFlow), amd64 only |
| Embedding | 75 hand-crafted timbre/rhythm features | 200-d learned MusiCNN embedding |
| Similarity | timbre, brightness, texture, pulse | closer to "musical style" |
| License | MIT | Essentia is AGPL-3.0 |

`auto` picks `essentia` when it is installed *and* its model file exists,
otherwise `dsp`. Switching backends re-analyzes the library (embeddings from
different backends cannot be compared); nothing needs to be deleted.

**The DSP backend** decodes a clip with ffmpeg and computes MFCC statistics,
spectral shape, band balance and rhythm/modulation features with numpy
([`analysis/dsp.py`](jellyamp_server/analysis/dsp.py) documents every
dimension). It groups music by how it *sounds* — a quiet piano piece lands
near other quiet piano pieces — but knows nothing about genre conventions or
mood the way a trained model does. It runs on anything, including a
Raspberry Pi.

**The Essentia backend** (full image):

```sh
docker build --build-arg WITH_ANALYSIS=1 -t jellyamp-server:full .
```

The build downloads the MusiCNN weights (`msd-musicnn-1.pb`, from
[Essentia's model site](https://essentia.upf.edu/models.html)) into
`/models`. If that download is not possible from your build machine, pass
another location with `--build-arg MUSICNN_MODEL_URL=…`, or build without it
by downloading the file yourself and mounting it:

```yaml
    volumes:
      - ./models:/models:ro     # contains msd-musicnn-1.pb
```

Outside Docker: `pip install -e ".[analysis]"` and set `MUSICNN_MODEL_PATH`.

**Loudness** is measured by ffmpeg's `ebur128` filter (integrated loudness
and true peak) with either backend, over the analyzed clip. For exact
whole-track values set `ANALYSIS_CLIP_SECONDS=0`.

## Sonic Sage

Set `ANTHROPIC_API_KEY` (from [console.anthropic.com](https://console.anthropic.com/))
and restart. The app then offers playlists from prompts like *"hazy guitars
for a rainy Sunday"*.

How it works, and what is shared: the server sends Claude your prompt plus a
**summary of your library** — genre names, decades and your most common
artist names with track counts. Claude answers with search criteria (genres,
years, artists to anchor on, energy); the server then picks and orders the
tracks itself from its own analysis. Track titles, your listening history and
audio never leave your server, and prompts are not logged. Each request is
billed to your Anthropic account (typically a few cents or less). Without the key the feature
is simply off and nothing is ever sent anywhere.

## Operations

```sh
# progress / status
curl -H "X-Api-Key: $KEY" http://localhost:8095/api/v1/info

# scan now (e.g. after adding an album)
curl -X POST -H "X-Api-Key: $KEY" http://localhost:8095/api/v1/scan

# also retry tracks that failed before
curl -X POST -H "X-Api-Key: $KEY" "http://localhost:8095/api/v1/scan?retryFailed=true"
```

Analysis makes Jellyfin transcode one clip per track (`ANALYSIS_CONCURRENCY`
at a time). On a small Jellyfin host, set it to `1` for the first scan.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Container exits immediately, `docker compose logs` shows `ERROR: jellyamp-server is not configured` | A required variable is missing in `.env`; the message says which. |
| `/info` shows `"lastError": "Jellyfin unreachable: …"` and `tracksTotal: 0` | `JELLYFIN_URL` is not reachable from the container. `localhost` inside the container is the container itself — use `host.docker.internal`, the service name, or the LAN IP. Test: `docker compose exec jellyamp-server python -c "import urllib.request; print(urllib.request.urlopen('$JELLYFIN_URL/System/Info/Public').read())"`. |
| `"lastError": "Jellyfin unreachable: Jellyfin answered HTTP 401"` | Wrong `JELLYFIN_API_KEY`. |
| App says the server is unauthorized | The key in the app differs from `SONIC_API_KEY`. |
| App cannot reach the server | Use the host's LAN address, not `localhost`; check that port 8095 is published and not firewalled. |
| `tracksAnalyzed` stays at 0, `tracksFailed` grows | Jellyfin cannot transcode (its ffmpeg is missing/broken): try playing a track with transcoding in the Jellyfin web UI. Logs show the reason per track. |
| A few tracks never get analyzed | Corrupt, silent or shorter than 3 s. They are listed in the logs (`analysis failed for …`) and skipped after `ANALYSIS_MAX_ATTEMPTS`. |
| `capabilities` is `[]` | Nothing analyzed yet — wait for the first scan. |
| No `sage` capability | `ANTHROPIC_API_KEY` is not set (check `docker compose logs`: `Sonic Sage enabled/disabled`). |
| Sonic Sage returns 502 | The detail says why: key rejected, model name unknown (`SAGE_MODEL`), rate limit, or no network access to `api.anthropic.com`. |
| `ANALYSIS_BACKEND=essentia but …` at startup | The slim image has no Essentia, or the model file is missing — see *Analysis backends*. |
| Similar tracks look odd right after setup | The DSP backend measures similarity relative to your library; results settle once most of it is analyzed. |
| Upgraded and the scan starts over | A new version changed the analysis or database format; the server re-analyzes automatically. |

## Development

```sh
python3 -m venv .venv
.venv/bin/pip install -e ".[dev]"
.venv/bin/pytest -q            # DSP tests need ffmpeg on PATH (skipped otherwise)
.venv/bin/ruff check .
```

Run locally against a Jellyfin:

```sh
JELLYFIN_URL=http://localhost:8096 JELLYFIN_API_KEY=… SONIC_API_KEY=$(openssl rand -hex 32) \
  .venv/bin/python -m jellyamp_server
```

End-to-end test against a real Jellyfin (opt-in; scans the library into a
temporary database and exercises every endpoint — written for the synthetic
library from `scripts/dev-jellyfin`):

```sh
JELLYFIN_URL=http://localhost:8096 JELLYFIN_API_KEY=… .venv/bin/pytest -m integration -s
```

The JSON fixtures in `tests/fixtures/` are the contract shared with the iOS
`SonicClient` tests; after editing them run `scripts/sync-fixtures.sh`.

Releases: pushing a tag `server-vX.Y.Z` publishes
`ghcr.io/<owner>/jellyamp-server` for amd64 and arm64
(`.github/workflows/server-image.yml`).

## Licensing

jellyamp-server itself is MIT-licensed like the rest of the repository. The
optional Essentia backend is AGPL-3.0, which applies to the *full* image
only; the default image does not contain it. See
[ADR-0004](../docs/adr/0004-fastapi-essentia-backend.md).
