# Audio Engine

Goal: Plexamp-class playback — audible crossfades, loudness leveling, silence
compression, 10-band EQ, visualizer — on iOS. This document describes the
engine as it is built; "Not yet" at the end lists what the original design
promised and the code does not do.

## Why AVAudioEngine (not AVQueuePlayer)

AVQueuePlayer gives near-gapless playback and free HTTP streaming, but no EQ
insertion point, no real crossfade (two `AVPlayer`s do not sum), no per-track
gain staging, and no PCM access for silence handling or a visualizer. Every
signature feature lives below the AVPlayer abstraction, so we own the graph
(ADR-0002). The earlier AVPlayer-based `EnginePlayer` has been removed.

## Files

| File | Role |
|---|---|
| `Services/Audio/AudioEnginePlayer.swift` | `PlayerEngine` implementation: queue, transport, crossfade state machine, loudness, reporting, engine recovery. Main thread. |
| `Services/Audio/StreamingAudioSource.swift` | Progressive decoder: bytes → `AudioFileStream` → `AudioConverter` → PCM buffers scheduled on a player node. Own serial queue. |
| `Services/Audio/TrackSchedulerNode.swift` | One chain: `AVAudioPlayerNode` → `AVAudioUnitEQ`. |
| `Services/Audio/StreamingAssetCache.swift` | Full-file download fallback when a remote file cannot be parsed progressively. |
| `Services/Audio/SpectrumTap.swift` | Mixer tap + vDSP FFT for the visualizer. |
| `Services/Audio/PlaybackSupport.swift` | `NetworkPathObserver`, `PlaybackReportSender`, `LoudnessService`. |
| `Services/SystemMediaController.swift` | Lock screen / remote commands / interruptions, driven by `PlayerStateModel`. |

Decisions that do not need Apple frameworks live in `JellyampCore` and are
unit-tested there: `PlayQueue`, `SweetFadePlanner`, `CrossfadeCurve`,
`SleepTimer`, `TransportPolicy`, `TrackFailurePolicy`, `PlaybackReporter`,
`PlaySessionLedger`, `PlaybackProfile`, `LoudnessLeveler`, `LoudnessCache`,
`SilenceGate`, `SpectrumBands`, `SpectrumSmoother`, `WaveformReducer`,
`DominantColor`, `AudioQualityInfo`.

## Node graph

```
PlayerNodeA ── AVAudioUnitEQ(A, 10-band) ──┐
                                           ├── MainMixer ──(tap: FFT → visualizer)── Output
PlayerNodeB ── AVAudioUnitEQ(B, 10-band) ──┘
```

Both chains are connected **once**, at a fixed engine format (44.1 kHz,
stereo, float). Sources convert to that format, so nodes are never
reconnected while the engine runs (reconnecting left nodes silent). One chain
is *active*; the other is idle except during a crossfade, when it carries the
incoming track. After the fade the roles swap.

## Streaming

`StreamingAudioSource.make(url:startTime:duration:…)` opens a byte stream (HTTP
or a local file), feeds it to `AudioFileStream`, decodes packets with
`AudioConverter` into 8192-frame buffers in the engine format and keeps about
three seconds scheduled ahead on the node. Playback starts after the header
and a first few packets — no full download. The source reports its end once
the bytes are exhausted and every scheduled buffer has played.

What is requested is decided on the main thread per track (`StreamPlan`):

1. **Downloaded** (`DownloadStore.localURL`): the local file. If it cannot be
   opened the remote path is tried.
2. **Direct play** (`PlaybackProfile` says the codec is native and the bitrate
   fits the cap for the current network): `/Items/{id}/File`. Seeking is a
   ranged request at `size × time / duration`; `AudioFileStream` resyncs. If
   the stream cannot be parsed, the file is downloaded once to
   `Caches/audio/` and read locally.
3. **Transcode** (codec not native — Vorbis, Opus, … — or bitrate above the
   cap, or "always transcode on cellular"): `/Audio/{id}/stream.mp3` via
   `StreamURLBuilder.progressiveURL` (the MP3 flavour of
   `progressiveTranscodeURL`), a progressive MP3 at the cap (max
   320 kbit/s). It is not byte-seekable: a seek re-requests with
   `startTimeTicks` and the source reads that stream from its first byte.
   (The HLS URL `StreamURLBuilder.url(for:request:)` builds is for AVPlayer;
   the stream parser cannot read a playlist.)

The network type comes from `NetworkPathObserver` (`NWPathMonitor`): cellular
*or* expensive (personal hotspot) paths use the cellular cap.

## Player state machine

`AudioEnginePlayer` is driven by user calls, by source-ended callbacks and by
a 10 Hz ticker (clock, crossfade ramp, sleep timer, progress reports).

- **Start of a track** (`startPlayback`): publish `.loading`, build the source
  off the main thread, then attach it to the active chain (`finishStart`).
  Every load carries a *start generation*; a completion whose generation is
  stale is discarded, so rapid skips cannot start the wrong track. Until the
  load lands (`startPending`) the previous audio may keep sounding, but its
  end no longer advances the queue and its position is not shown.
- **Seek** rebuilds the source at the target time through the same path, but
  is *not* a new start: it keeps the paused/playing intent (a seek while
  paused schedules buffers and leaves the node stopped) and sends a progress
  report, never a start report. A seek that cannot be opened leaves the old
  source playing.
- **Clock**: `startOffset + node sample time (+ silence skipped)`. A paused
  node has no player time; the last known position is held.
- **End of track**: `PlayQueue.advance()` (honours repeat one/all); at the
  end of the queue the engine goes idle. "Previous" restarts the track after
  3 s (`TransportPolicy`).
- **Failures** (`TrackFailurePolicy`): a track that cannot be loaded is
  skipped; after three consecutive failures the engine stops on the failed
  track and `play()` retries it.

### Crossfade

Each tick, while playing and not already fading, the engine asks
`SweetFadePlanner` for the overlap between the current and the next track:

- consecutive tracks of the same album (same disc, next index) → 0: the
  tracks are joined end to start, never faded (live albums, DJ mixes);
- otherwise the user's crossfade duration, at most half of either track.

When the remaining time drops below the overlap, the next track is loaded
onto the idle chain at volume 0 and both node volumes follow the equal-power
`CrossfadeCurve` on the wall clock. At the end the chains swap and the queue
advances. Rules around it:

- a *crossfade generation* discards an incoming source that finishes loading
  after its crossfade was cancelled;
- queue edits, repeat or shuffle changes that make another track "next"
  cancel the fade (audio and queue must agree on what plays);
- "next" during a fade completes the handover instead of restarting the
  incoming track; pausing freezes the ramp;
- if the incoming track cannot be loaded the fade is dropped and not retried;
  if the outgoing track runs out first, the incoming one takes over at once;
- no crossfade starts while the sleep timer is in "end of track" mode.

### Sleep timer

`SleepTimer` (Core). Timed: the output fades over `sleepTimerFadeOut`, then
playback **pauses** (queue and position survive, level restored). End of
track: the track plays out without a crossfade and the queue parks, paused,
on the next track.

## Loudness leveling

`LoudnessLeveler` (Core) picks a gain per queue position:

1. the track's Jellyfin `NormalizationGain` tag;
2. else a measured value: `SonicProviding.loudness(forTrack:)` through the
   injected `loudnessLookup` closure (`LoudnessService`: disk cache in
   `Caches/loudness/measured.json`, then the sonic server when it advertises
   the `loudness` capability) → gain = −18 LUFS − measured LUFS;
3. **album context**: when the neighbours in the queue are from the same
   album, every track of that run uses one gain — the album's own
   `NormalizationGain` (`albumGainLookup`) or, without it, the lowest track
   gain of the run — so an album never changes level between tracks.

The gain plus the user preamp becomes a `GainStage`: attenuation is applied
on the player node's volume (which also carries master volume, crossfade and
sleep-timer fades); a boost is only granted inside known headroom
(true peak + boost ≤ 0 dBTP, max +12 dB) and is applied as the chain EQ's
`globalGain`. Without a known peak nothing is boosted. Missing values are
fetched when a track starts (current album run + next track) and applied
when they arrive.

## Silence compression

Opt-in (`settings.silenceCompressionEnabled`). `StreamingAudioSource` shows
every decoded buffer's peak to a `SilenceGate` (Core) just before scheduling.
Buffers that are silent throughout (peak < −60 dBFS) are dropped once a
silent stretch exceeds its allowance: 0.5 s before the first audible buffer,
2 s inside and at the end of a track. Only whole buffers (≈ 0.19 s) are
dropped — nothing is spliced, nothing audible is removed. The dropped time is
added to the clock so the scrubber shows the position in the file. With the
setting off the gate is nil and scheduling is exactly as before. The setting
is read when a source is created (next track or seek).

## EQ

`AVAudioUnitEQ` (10 bands) per chain; `EQPreset` (Core) defines the bands;
both chains are updated together. Presets are the built-ins in `EQPreset`.

## Visualizer

`SpectrumTap` installs a tap on the main mixer (observation only — not part
of the render path) while at least one view retains it
(`AudioSpectrumProviding.retainSpectrum/releaseSpectrum`). `SpectrumAnalyzer`
runs a 2048-point Hann-windowed FFT (vDSP) per block and hands per-bin power
to `SpectrumBands` (32 log-spaced bands, dB scaling, treble tilt); the result
and a 96-point waveform go into `SpectrumStore`, a lock-protected mailbox.
`VisualizerView` reads it from a 30 fps `TimelineView`/`Canvas` and animates
with `SpectrumSmoother` (attack, decay, peak hold). The tap is removed when
the view disappears, the app is inactive, Low Power Mode is on or Reduce
Motion is requested, and is re-installed after engine restarts.

## System integration

- **Engine stops** (`AVAudioEngineConfigurationChange`, media-services reset,
  or `play()` finding the engine stopped after an interruption): the current
  track is rebuilt at its position through the seek path, which restarts the
  engine and re-activates the session.
- **Interruptions / route loss**: `SystemMediaController` pauses; it resumes
  when the system says so.
- **Now Playing info**: elapsed time is pushed only when the real position
  differs from what the system extrapolates (seek, stall, pause).
- **Playback reports** (`PlaybackReporter` → `PlaybackReportSender`, strictly
  ordered): start when audio begins, progress every 10 s and immediately on
  pause/resume/seek, stop with the final position on track change, queue end
  and teardown; one `PlaySessionId` per play-through. Jellyfin increments
  `PlayCount` and sets `LastPlayedDate` on the *start* report.

## Verification

- Core logic: `swift test` in `ios/Packages/JellyampCore`.
- Report contract against a real server:
  `JELLYFIN_TEST_URL=… swift test --filter PlaybackIntegrationTests` in
  `ios/Packages/JellyfinBackend`.
- State machine: `scripts/engine-sim/run.sh` compiles the real
  `AudioEnginePlayer` against fake audio nodes on Linux and plays scenarios
  (queue end, seek while paused, skip races, crossfade, queue edits during a
  fade, failures, sleep timers, engine restarts, loudness, transcodes,
  reports). It proves control flow, not sound.
- Anything audible — decode, scheduling, the fades themselves, AirPlay,
  interruptions on real hardware — needs a device.

## Not yet

- **Sample-accurate gapless.** Same-album joins are end-to-start with a new
  source on the same chain; there is a short gap while it opens. `GaplessPlan`
  and `SilenceTrimmer` (Core) are the pieces a pre-scheduled join would use.
- **Seeking inside containers that need their header** (MP4/M4A, possibly
  FLAC) by byte offset: the fresh stream parser may not sync mid-file; the
  seek then fails and playback continues at the old position.
- **Network drop mid-track** ends the source early and is treated as the end
  of the track.
- **Media-services reset** reuses the existing `AVAudioEngine` instance.
- **AirPlay 2 buffered playback**: output goes through normal session
  routing.
- **Custom EQ presets** (only built-ins are persisted via `activeEQPresetID`).
