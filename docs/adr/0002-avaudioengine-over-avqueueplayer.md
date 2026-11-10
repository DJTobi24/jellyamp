# ADR-0002: AVAudioEngine dual-node graph instead of AVQueuePlayer

## Status
Accepted; amended for 1.0 (see the end).

## Context
Plexamp's signature playback features — sample-accurate gapless, equal-power
crossfades, per-track loudness gain, 10-band EQ, silence trimming, FFT
visualizers — all require access below AVPlayer: PCM buffers, an effects
insertion point, and per-source gain staging. AVQueuePlayer offers none of
these; faking crossfades with two AVPlayers is fragile and never
sample-accurate.

## Decision
Use AVAudioEngine with two alternating AVAudioPlayerNode→AVAudioUnitEQ chains
into the main mixer. Stream HTTP audio via a progressive download-to-file
cache (`StreamingAssetCache`) because `AVAudioFile` requires a real seekable
file and `AVAssetResourceLoader` only serves AVPlayer.

## Consequences
- We own buffering, seeking, and route/interruption handling (more code,
  centralized in `EnginePlayer`/`StreamingAssetCache`).
- The cache doubles as the offline-download write path.
- All DSP math (fade curves, gain, silence detection) lives as pure Swift in
  `JellyampCore` and is unit-tested on Linux.

## Amendment for 1.0
The graph is as decided. Two details changed while building it;
`docs/AUDIO-ENGINE.md` describes the engine as built:

- **Streaming.** Audio is not downloaded to a file first.
  `StreamingAudioSource` parses the byte stream with `AudioFileStream`,
  decodes with `AudioConverter` and schedules PCM buffers, so playback starts
  after the first packets. `StreamingAssetCache` remains only as the
  full-file fallback for streams that cannot be parsed progressively, and it
  is not the download path: downloads have their own background session
  (`Services/Downloads`).
- **Gapless.** Consecutive album tracks are joined end to start without a
  fade, but not sample-accurately: there is a short gap while the next source
  opens. The class is `AudioEnginePlayer`; the AVPlayer-based `EnginePlayer`
  is gone.
