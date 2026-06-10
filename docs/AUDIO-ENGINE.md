# Audio Engine Design

Goal: Plexamp-class playback — true gapless, "sweet" crossfades, loudness
leveling, silence compression, 10-band EQ, visualizer — on iOS.

## Why AVAudioEngine (not AVQueuePlayer)

AVQueuePlayer gives near-gapless playback and free HTTP streaming, but no EQ
insertion point, no sample-accurate crossfade, no per-track gain staging, and
no PCM access for silence trimming or visualizers. Every signature feature
lives below the AVPlayer abstraction, so we own the graph (ADR-0002).

## Node graph

```
PlayerNodeA ── AVAudioUnitEQ(A, 10-band) ──┐
                                           ├── MainMixer ── (tap: FFT → visualizer) ── Output
PlayerNodeB ── AVAudioUnitEQ(B, 10-band) ──┘
```

Two `TrackSchedulerNode` chains alternate per track (A plays N, B is preloaded
with N+1, swap, repeat).

## Gapless

- `SilenceTrimmer` (JellyampCore) scans decoded PCM for the first/last frames
  above threshold; `GaplessPlan` records the playable `[start, end)` frame
  range and fade windows per track.
- Track N+1's first buffer is scheduled on the idle chain with an explicit
  `AVAudioTime` equal to track N's trimmed end frame → sample-accurate joins,
  including across album-side track boundaries (live albums, DJ mixes).

## Sweet fades (crossfade)

- `CrossfadeCurve` (Core, unit-tested): equal-power curves; the "sweet"
  profile shortens the fade when the outgoing track ends cold and **skips the
  fade entirely** between consecutive tracks of the same album whose join is
  gapless (detected via trimmed silence ≈ 0 + same album).
- Applied as `playerNode.volume` ramps per render quantum during the overlap
  window; per-track loudness gain multiplies underneath.

## Loudness leveling

- Source of truth: Jellyfin's `NormalizationGain` (dB, available since 10.9)
  on items; `LoudnessMath` (Core) converts dB → linear gain, applies user
  pre-amp, and clamps to prevent clipping using track peak when known.
- Fallbacks, in order: album gain → jellyamp-server `GET /api/v1/loudness/{id}`
  (computed EBU R128) → quick first-buffer estimate (Phase 4).

## Silence compression

Because we decode PCM ourselves, mid-track silences > 2 s can be skipped by
scheduling around them (opt-in setting; off by default).

## EQ / DSP

`AVAudioUnitEQ` (10 bands) per chain; `EQPreset` (Codable, Core) defines
band frequencies/gains; both chains are updated together so a preset change is
seamless across a crossfade.

## Streaming: progressive download-to-file

`AVAudioFile` needs a real seekable file, and `AVAssetResourceLoader` only
helps AVPlayer. So `StreamingAssetCache`:

- downloads `/Audio/{id}/universal` via URLSession into
  `Library/Caches/audio/{itemId}.{ext}` and exposes bytes-available progress;
- `TrackSchedulerNode` opens the growing file with `AVAudioFile` and schedules
  buffers behind the write head (sequential reads keep FLAC/ALAC frame
  boundaries safe);
- **direct play** (`static=true`): byte-range seekable — seeking issues a
  ranged request from the new offset (Phase 1 simplification: restart download
  at offset);
- **transcode**: not byte-seekable — seek = new request with `startTimeTicks`,
  new cache generation;
- a fully downloaded cache entry promoted to permanent storage *is* an offline
  download (single write path).

## Direct-play vs transcode decision

`PlaybackProfile` (Core, pure): inputs are item codec/container/bitrate, user
settings (cellular cap, "transcode to AAC on cellular"), and network type;
output is a `StreamRequest` (static, or container/codec/bitrate). iOS decodes
FLAC/ALAC/AAC/MP3/Opus(≥17) natively, so direct play is the default on Wi-Fi.

## Visualizer

`installTap(onBus:)` on the main mixer → vDSP FFT → published frequency
buckets consumed by `VisualizerView` (SwiftUI Canvas/Metal, tinted by dominant
album-art colors).

## AirPlay note

AVAudioEngine output routes through normal AVAudioSession routing, so AirPlay
works as a route. AirPlay-2 multi-room buffered streaming (AVPlayer-style
`AVSampleBufferAudioRenderer` long-buffer mode) is a possible Phase 4
investigation; standard AirPlay routing ships in Phase 2.
