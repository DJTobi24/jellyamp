# ADR-0004: Python + FastAPI for jellyamp-server, with pluggable analysis (DSP default, Essentia optional)

## Status
Accepted; amended for server v1 (the analysis backend is now pluggable and
the default no longer requires Essentia).

## Context
Jellyfin has no audio analysis; Plexamp-grade sonic features (similarity,
Sonic Adventure, auto-mixes) need per-track audio embeddings. Mature
pretrained music-embedding models (MusiCNN, EffNet-Discogs) ship with
Essentia's Python bindings; the MIR ecosystem is Python-first.

The original decision made Essentia/MusiCNN *the* analysis pipeline. In
practice that pipeline never ran for a self-hoster out of the box:

- `essentia-tensorflow` is a ~1 GB dependency with x86-64-only Linux wheels —
  no arm64, so no Raspberry Pi and no Apple-silicon Docker without emulation.
- The MusiCNN weights are a separate download that the image did not contain.
- Essentia is AGPL-3.0, which a default image would impose on every user.

A companion that reports "0 tracks analyzed" until the user sources a model
file is not a product. The server needs an analysis path that works with
`docker compose up` on any machine, and may offer the learned model as an
upgrade.

## Decision
`server/` is Python 3.11 + FastAPI, with SQLite as the single-file store,
packaged as one Docker container configured via env vars (`JELLYFIN_URL`,
`JELLYFIN_API_KEY`, `SONIC_API_KEY`). Pydantic response models double as the
contract in docs/SONIC-API.md; fixtures are shared with the iOS
`SonicClientTests`.

Analysis is an `Extractor` interface (`analysis/base.py`: encoded clip in,
embedding + loudness out, plus a `name/version` identity) with two
implementations selected by `ANALYSIS_BACKEND` (`auto` by default):

1. **`dsp` — built in, the default.** The `ffmpeg` binary decodes a clip and
   measures EBU R128 loudness/true peak (`ebur128` filter); numpy computes a
   75-dimensional timbre/rhythm descriptor (MFCC statistics, spectral shape,
   band balance, onset/tempo and modulation features). No model, no
   TensorFlow, multi-arch, MIT.
2. **`essentia` — optional.** MusiCNN embeddings via `essentia-tensorflow`
   (the `analysis` extra / `WITH_ANALYSIS=1` image). `auto` uses it only when
   the package *and* the model file are present.

Each stored embedding records the extractor identity that produced it. Only
embeddings of the active extractor are served, and the scanner re-analyzes
everything else, so switching backends (or shipping an improved DSP version)
needs no manual migration.

Because hand-crafted features are heterogeneous (octaves, ratios, cepstra),
the similarity index standardizes them across the library and applies
per-group weights before cosine distance; learned embeddings are used as-is.
The index is one in-memory matrix rebuilt after writes — brute force is
milliseconds up to a few hundred thousand tracks, so sqlite-vec (named in the
original decision) is not needed yet and was dropped as a dependency.

Analysis input is a bounded clip (default 90 s from the middle of the track)
fetched as a fixed-bitrate MP3 transcode from Jellyfin: one predictable
format for every source codec, and the download can stop after N bytes.

## Consequences
- `docker compose up` yields working sonic features on amd64 and arm64 with
  a small image; the AGPL dependency exists only in the optional full image.
- DSP similarity is cruder than a learned embedding: it captures timbre,
  brightness, texture and pulse, not genre conventions or mood. Sounds that
  differ only subtly (in the synthetic test library: two bare two-sine
  "voices" that differ by a 3 Hz tremolo) are separable by centroid but can
  interleave as nearest neighbours. Users who want more can switch to
  MusiCNN; a permissively licensed ONNX/CLAP backend fits the same interface.
- DSP distances are relative to the library (standardization), so they are
  comparable within one server, not across servers, and shift slightly as
  the library grows.
- Loudness is measured over the analyzed clip, an approximation of the
  whole-track value unless `ANALYSIS_CLIP_SECONDS=0`; it is measured on a
  192 kbps MP3 transcode, which can move true peak by a few tenths of a dB.
- Analysis cost moves partly to Jellyfin (one clip transcode per track);
  concurrency is bounded and configurable.
- Throughput with the DSP backend is roughly 1–3 tracks/s; incremental scans
  make this a one-time cost per library.
