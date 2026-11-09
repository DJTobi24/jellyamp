import Foundation
import AVFoundation
import AudioToolbox
import OSLog
import JellyampCore
import JellyfinBackend

/// `AVAudioEngine`-based player: two `AVAudioPlayerNode` chains feed one mixer,
/// so they **mix** — enabling a real, audible crossfade (two separate
/// `AVPlayer`s won't sum). Audio is decoded progressively from the network with
/// `StreamingAudioSource` (no full download; falls back to a cached download if
/// the remote isn't readable progressively). The next track is prepared so
/// transitions stay seamless. Graphic EQ works on each chain.
///
/// Everything here runs on the main thread except `makeSource`, which only
/// touches the immutable `StreamPlan` it is given. See docs/AUDIO-ENGINE.md.
final class AudioEnginePlayer: NSObject, PlayerEngine, ObservableObject, AudioSpectrumProviding {
    @Published private(set) var state: PlaybackState = .idle
    private(set) var currentTime: TimeInterval = 0

    private final class Chain {
        let scheduler: TrackSchedulerNode
        var source: StreamingAudioSource?
        var startOffset: TimeInterval = 0
        /// Last position read from the node. A paused or not-yet-rendering
        /// node has no player time; this keeps the clock where it was instead
        /// of snapping back to `startOffset`.
        var lastPosition: TimeInterval = 0
        var generation = 0
        var player: AVAudioPlayerNode { scheduler.player }
        init(engine: AVAudioEngine) {
            scheduler = TrackSchedulerNode(engine: engine)
            scheduler.attach(to: engine)
        }
    }

    /// Everything `makeSource` needs, decided on the main thread so the
    /// background load never reads mutable player state.
    private struct StreamPlan {
        let track: Track
        let localURL: URL?
        let request: StreamRequest
        let quality: AudioQualityInfo
        let silenceGate: SilenceGate?

        /// Jellyfin's `PlayMethod` for playback reports.
        var playMethod: String { quality.delivery == .transcoded ? "Transcode" : "DirectPlay" }
    }

    private let engine = AVAudioEngine()
    private let engineFormat: AVAudioFormat
    private let chainA: Chain
    private let chainB: Chain
    private var activeIsA = true
    private var active: Chain { activeIsA ? chainA : chainB }
    private var idle: Chain { activeIsA ? chainB : chainA }

    private let session: JellyfinSession
    private var settings: AppSettings
    private var queue = PlayQueue()
    private var reporter = PlaybackReporter()
    private let reportSender: PlaybackReportSender
    private let cache: StreamingAssetCache
    private weak var stateModel: PlayerStateModel?

    private var masterVolume: Float = 1.0
    private var loudnessGain: Float = 1.0
    private var sessionActivated = false
    private var intendsToPlay = false
    private var shuffleEnabled = false
    private var preferredRepeatMode: RepeatMode = .off
    private var eqPreset: EQPreset?

    private var sleepTimer = SleepTimer()
    private var monotonicNow: TimeInterval { Date().timeIntervalSinceReferenceDate }

    private var fadePlanner: SweetFadePlanner
    private enum Transition: Equatable { case none, crossfading }
    private var transition: Transition = .none
    private var crossfadeStart: TimeInterval = 0
    private var crossfadeOverlap: TimeInterval = 0
    private var incomingTrack: Track?
    private var incomingLoudness: Float = 1.0
    /// Bumped whenever a crossfade begins or is cancelled, so an incoming
    /// source that finishes loading for a cancelled crossfade is discarded.
    private var crossfadeGeneration = 0
    private var incomingPlan: StreamPlan?
    private var incomingBoostDB: Double = 0
    /// The outgoing track ran out while the incoming one was still loading.
    private var outgoingEndedDuringTransition = false
    /// Incoming track that could not be loaded for a crossfade; not retried
    /// as a crossfade (the regular start path handles it, with skip-on-failure).
    private var failedIncomingTrackID: String?
    private var pausedAt: TimeInterval = 0

    private var ticker: Timer?
    private var startGeneration = 0
    /// A track start or seek is loading; the active chain may still be
    /// sounding the previous audio until it lands.
    private var startPending = false
    /// The pending load is the first start of the current track (as opposed
    /// to a seek within it), and where the previous track had got to.
    private var pendingIsNewTrack = false
    private var pendingPreviousPosition: TimeInterval = 0
    /// The active chain drained while a seek was loading.
    private var activeEndedWhilePending = false
    private var lastEngineRecovery: TimeInterval = 0

    private let transportPolicy = TransportPolicy()
    private var failurePolicy = TrackFailurePolicy()

    // Loudness leveling.
    private let leveler = LoudnessLeveler()
    private var measuredLoudness: [String: MeasuredLoudness] = [:]
    private var albumGains: [String: Double] = [:]
    private var loudnessRequested: Set<String> = []
    private var albumGainRequested: Set<String> = []
    private var activeBoostDB: Double = 0
    private var currentPlayMethod = "DirectPlay"

    /// Measured loudness for a track without a `NormalizationGain` tag
    /// (sonic server). Injected by the container; nil disables the fallback.
    var loudnessLookup: (@Sendable (_ trackID: String) async -> MeasuredLoudness?)?
    /// Album-level gain in dB (Jellyfin's album `NormalizationGain`), used for
    /// consecutive tracks of one album. Optional; without it the engine
    /// derives a shared gain from the tracks themselves.
    var albumGainLookup: (@Sendable (_ albumID: String) async -> Double?)?

    // Visualizer.
    let spectrum = SpectrumStore()
    private lazy var spectrumTap = SpectrumTap(store: spectrum)
    private var spectrumConsumers = 0

    private let log = Logger(subsystem: "dev.djtobi.Jellyamp", category: "Playback")

    init(session: JellyfinSession, settings: AppSettings, stateModel: PlayerStateModel) {
        self.session = session
        self.settings = settings
        self.reportSender = PlaybackReportSender(api: PlaybackReportingAPI(session: session))
        self.cache = StreamingAssetCache(session: session)
        self.stateModel = stateModel
        self.sleepTimer = SleepTimer(fadeOutDuration: settings.sleepTimerFadeOut)
        self.fadePlanner = SweetFadePlanner(fadeDuration: settings.crossfadeDuration)
        self.engineFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        self.chainA = Chain(engine: engine)
        self.chainB = Chain(engine: engine)
        super.init()
        // Fixed engine format on both chains, connected once — the streaming
        // sources convert to it, so we never reconnect nodes (which can leave
        // a node silent while the engine is running).
        for chain in [chainA, chainB] {
            engine.connect(chain.player, to: chain.scheduler.eq, format: engineFormat)
            engine.connect(chain.scheduler.eq, to: engine.mainMixerNode, format: engineFormat)
        }
        engine.prepare()
        _ = NetworkPathObserver.shared   // start watching the path before the first stream decision
        NotificationCenter.default.addObserver(
            self, selector: #selector(engineConfigurationChanged(_:)),
            name: .AVAudioEngineConfigurationChange, object: engine)
        NotificationCenter.default.addObserver(
            self, selector: #selector(mediaServicesWereReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        log.info("AudioEnginePlayer init (progressive streaming)")
    }

    deinit {
        ticker?.invalidate()
        NotificationCenter.default.removeObserver(self)
        // Sign-out / teardown: close the Jellyfin session for the playing track.
        reportSender.send(reporter.stopped(at: currentTime), playMethod: currentPlayMethod)
    }

    // MARK: - PlayerEngine

    func load(queue: PlayQueue) {
        var queue = queue
        queue.setRepeatMode(preferredRepeatMode)
        if shuffleEnabled { queue.shuffle() }
        self.queue = queue
        guard let track = queue.currentTrack else { return }
        failurePolicy.recordSuccess()   // a new choice by the user gets a fresh failure budget
        startPlayback(of: track)
    }

    func play() {
        guard let track = queue.currentTrack else { return }
        let wasIntending = intendsToPlay
        intendsToPlay = true
        activateSession()
        if startPending {
            // A start or seek is still loading; it starts the node itself now
            // that playback is wanted.
            publish(state: .loading(trackID: track.id), track: track)
            startTicker()
            return
        }
        if active.source == nil {
            // Nothing is attached: after a failed load, or parked by the
            // end-of-track sleep timer. Start the current track from the top.
            startPlayback(of: track)
            return
        }
        if !engine.isRunning {
            // The system stopped the engine underneath us (interruption,
            // route change). What was scheduled is not reliably still there,
            // so rebuild the track at the position it had reached.
            restartCurrentTrack(at: currentTime)
            reportStateChange()
            return
        }
        if !wasIntending, transition == .crossfading, crossfadeStart > 0 {
            // The fade ramp runs on wall-clock time; do not count the pause.
            crossfadeStart += monotonicNow - max(pausedAt, crossfadeStart)
        }
        active.player.play()
        if transition == .crossfading { idle.player.play() }
        publish(state: .playing(trackID: track.id), track: track)
        startTicker()
        reportStateChange()
    }

    func pause() {
        guard let track = queue.currentTrack else { return }
        if intendsToPlay { pausedAt = monotonicNow }
        intendsToPlay = false
        active.player.pause()
        idle.player.pause()
        publish(state: .paused(trackID: track.id), track: track)
        reportStateChange()
    }

    func seek(to time: TimeInterval) {
        guard let track = queue.currentTrack else { return }
        restartCurrentTrack(at: transportPolicy.clampedSeekTarget(time, duration: track.duration))
        // A seek is a progress report in the same play session. Sending a new
        // "start" here would make Jellyfin count another play per seek.
        reportStateChange()
    }

    func skipToNext() {
        if transition == .crossfading, crossfadeStart > 0, intendsToPlay {
            // The next track is already fading in — complete the handover
            // instead of restarting that track from the top.
            finishCrossfade()
            return
        }
        guard let next = queue.skipToNext() else { return }
        startPlayback(of: next)
    }

    func skipToPrevious() {
        switch transportPolicy.previousAction(position: currentTime, hasPrevious: queue.hasPrevious) {
        case .restartCurrent:
            seek(to: 0)
        case .previousTrack:
            guard let previous = queue.skipToPrevious() else { return }
            startPlayback(of: previous)
        }
    }

    func setVolume(_ volume: Double) {
        masterVolume = Float(volume)
        applyEffectiveVolume()
    }

    func enqueue(_ tracks: [Track]) {
        let wasIdle = queue.currentTrack == nil
        queue.append(tracks)
        publishQueue()
        if wasIdle, let track = queue.currentTrack { startPlayback(of: track) } else { queueEdited() }
    }

    func playNext(_ tracks: [Track]) {
        let wasIdle = queue.currentTrack == nil
        queue.insertNext(tracks)
        publishQueue()
        if wasIdle, let track = queue.currentTrack { startPlayback(of: track) } else { queueEdited() }
    }

    func playUpNext(at upNextIndex: Int) {
        guard let absolute = queue.absoluteIndex(forUpNext: upNextIndex) else { return }
        queue.jump(to: absolute)
        guard let track = queue.currentTrack else { return }
        startPlayback(of: track)
    }

    func playFromHistory(at historyIndex: Int) {
        guard queue.history.indices.contains(historyIndex) else { return }
        queue.jump(to: historyIndex)
        guard let track = queue.currentTrack else { return }
        startPlayback(of: track)
    }

    func removeUpNext(at upNextIndex: Int) {
        guard let absolute = queue.absoluteIndex(forUpNext: upNextIndex) else { return }
        queue.remove(at: absolute)
        publishQueue()
        queueEdited()
    }

    func moveUpNext(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let from = source.first else { return }
        let base = (queue.currentIndex ?? -1) + 1
        queue.move(from: base + from, to: base + (destination > from ? destination - 1 : destination))
        publishQueue()
        queueEdited()
    }

    func clearUpNext() {
        queue.clearUpNext()
        publishQueue()
        queueEdited()
    }

    func setShuffle(_ enabled: Bool) {
        shuffleEnabled = enabled
        if enabled { queue.shuffle() } else { queue.unshuffle() }
        publishQueue()
        publishShuffleRepeat()
        queueEdited()
    }

    func cycleRepeatMode() {
        switch preferredRepeatMode {
        case .off: setRepeatMode(.all)
        case .all: setRepeatMode(.one)
        case .one: setRepeatMode(.off)
        }
    }

    func setRepeatMode(_ mode: RepeatMode) {
        preferredRepeatMode = mode
        queue.setRepeatMode(mode)
        publishShuffleRepeat()
        queueEdited()
    }

    func playShuffled(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        shuffleEnabled = true
        var fresh = PlayQueue(tracks: tracks, startAt: Int.random(in: 0..<tracks.count))
        fresh.setRepeatMode(preferredRepeatMode)
        fresh.shuffle()
        queue = fresh
        failurePolicy.recordSuccess()
        if let track = queue.currentTrack { startPlayback(of: track) }
        publishShuffleRepeat()
    }

    func setFavorite(trackID: String, isFavorite: Bool) {
        queue.updateTracks(id: trackID) { $0.isFavorite = isFavorite }
        if incomingTrack?.id == trackID { incomingTrack?.isFavorite = isFavorite }
        publishQueue()
        if let current = queue.currentTrack, current.id == trackID, stateModel?.currentTrack?.id == trackID {
            stateModel?.currentTrack = current
        }
    }

    func apply(eqPreset: EQPreset) {
        self.eqPreset = eqPreset
        chainA.scheduler.apply(preset: eqPreset)
        chainB.scheduler.apply(preset: eqPreset)
    }

    func updateSettings(_ newSettings: AppSettings) {
        let old = settings
        settings = newSettings
        fadePlanner.fadeDuration = newSettings.crossfadeDuration
        sleepTimer.fadeOutDuration = newSettings.sleepTimerFadeOut
        if old.loudnessLevelingEnabled != newSettings.loudnessLevelingEnabled
            || old.loudnessPreampDB != newSettings.loudnessPreampDB {
            // Leveling changes are audible feedback for the settings screen:
            // apply them to the playing track, not just the next one.
            refreshActiveLoudness()
            requestLoudness()
        }
    }

    func startSleepTimer(duration: TimeInterval?) {
        if let duration { sleepTimer.start(duration: duration, now: monotonicNow) }
        else { sleepTimer.startEndOfTrack() }
        publishSleepTimer()
        // The countdown must run even when nothing has started the ticker yet.
        startTicker()
    }

    func cancelSleepTimer() {
        sleepTimer.cancel()
        applyEffectiveVolume()
        publishSleepTimer()
    }

    // MARK: - AudioSpectrumProviding

    func retainSpectrum() {
        spectrumConsumers += 1
        if engine.isRunning { spectrumTap.install(on: engine.mainMixerNode) }
    }

    func releaseSpectrum() {
        spectrumConsumers = max(0, spectrumConsumers - 1)
        if spectrumConsumers == 0 { spectrumTap.remove(from: engine.mainMixerNode) }
    }

    // MARK: - Playback

    private func startPlayback(of track: Track) {
        cancelTransition()
        intendsToPlay = true
        failedIncomingTrackID = nil
        // Where the last track that actually started had got to, for its
        // final report (skipping twice quickly must not report 0).
        let previousPosition = (startPending && pendingIsNewTrack) ? pendingPreviousPosition : currentTime
        let stage = gainStage(forQueueIndex: queue.currentIndex)
        loudnessGain = Float(stage.volume)
        activeBoostDB = stage.boostDB
        publish(state: .loading(trackID: track.id), track: track)
        publishQueue()
        publishShuffleRepeat()
        requestLoudness()
        beginStart(of: track, at: 0, isNewTrack: true, previousPosition: previousPosition)
    }

    /// Rebuilds the current track's decoder at `time` — a seek, or recovery
    /// after the engine was stopped by the system. Keeps the paused/playing
    /// intent; sends no reports (the caller decides).
    private func restartCurrentTrack(at time: TimeInterval) {
        guard let track = queue.currentTrack else { return }
        // Seeking while the track's first start is still loading replaces
        // that load; it must still count (and be reported) as the start, and
        // the chain is still sounding the *previous* track.
        // The same holds when nothing is attached at all (track parked by
        // the sleep timer, or failed): this load is its first start.
        let replacesFirstStart = startPending ? pendingIsNewTrack : active.source == nil
        let previousPosition = replacesFirstStart ? pendingPreviousPosition : time
        cancelTransition()
        beginStart(of: track, at: time, isNewTrack: replacesFirstStart, previousPosition: previousPosition)
    }

    private func beginStart(of track: Track, at time: TimeInterval, isNewTrack: Bool, previousPosition: TimeInterval) {
        let generation = bumpStartGeneration()
        startPending = true
        pendingIsNewTrack = isNewTrack
        pendingPreviousPosition = previousPosition
        setCurrentTime(time)
        let plan = streamPlan(for: track)
        Task { [weak self] in
            guard let self else { return }
            let source = await self.makeSource(plan: plan, startTime: time)
            await self.finishStart(generation: generation, plan: plan, source: source, startOffset: time,
                                   isNewTrack: isNewTrack, previousPosition: previousPosition)
        }
    }

    @MainActor
    private func finishStart(generation: Int, plan: StreamPlan, source: StreamingAudioSource?, startOffset: TimeInterval,
                             isNewTrack: Bool, previousPosition: TimeInterval) {
        guard startGeneration == generation else { source?.stop(); return }
        startPending = false
        pendingIsNewTrack = false
        let track = plan.track
        guard let source else {
            if isNewTrack { handleLoadFailure(of: track) } else { handleSeekFailure(of: track) }
            return
        }
        failurePolicy.recordSuccess()
        activeEndedWhilePending = false
        // A seek while paused stays paused: the buffers are scheduled and the
        // node starts with the next play().
        play(track, source: source, on: active, startOffset: startOffset, startNode: intendsToPlay)
        currentPlayMethod = plan.playMethod
        stateModel?.quality = plan.quality
        if intendsToPlay {
            publish(state: .playing(trackID: track.id), track: track)
        } else {
            publish(state: .paused(trackID: track.id), track: track)
        }
        startTicker()
        if isNewTrack {
            report(reporter.trackStarted(id: track.id, at: startOffset, previousPosition: previousPosition))
        }
    }

    /// A track could not be loaded at all. Stop what is left of the previous
    /// one and move on — one broken file must not stall the queue — unless
    /// several fail in a row (server unreachable), then stay put.
    private func handleLoadFailure(of track: Track) {
        log.error("load failed: \"\(track.title, privacy: .public)\"")
        active.source?.stop()
        active.player.stop()
        active.source = nil
        publish(state: .failed(trackID: track.id, message: String(localized: "Couldn't load track.")), track: track)
        switch failurePolicy.recordFailure() {
        case .skipToNext:
            if let next = queue.skipToNext(), next.id != track.id {
                startPlayback(of: next)
            } else {
                intendsToPlay = false
            }
        case .giveUp:
            intendsToPlay = false
        }
    }

    /// The seek target could not be opened (e.g. a container the stream
    /// parser cannot enter mid-file). The previous decoder was never touched,
    /// so playback simply continues where it was.
    private func handleSeekFailure(of track: Track) {
        log.error("seek failed for \"\(track.title, privacy: .public)\" — continuing at the old position")
        guard active.source != nil else {
            publish(state: .failed(trackID: track.id, message: String(localized: "Couldn't load track.")), track: track)
            intendsToPlay = false
            return
        }
        setCurrentTime(active.lastPosition)
        if activeEndedWhilePending {
            activeEndedWhilePending = false
            trackFinished()
        }
    }

    /// Attaches a source to a chain and (normally) starts the node.
    private func play(_ track: Track, source: StreamingAudioSource, on chain: Chain, startOffset: TimeInterval, startNode: Bool) {
        activateSession()
        chain.source?.stop()
        chain.source = source
        chain.startOffset = startOffset
        chain.lastPosition = startOffset
        let generation = chain.generation + 1
        chain.generation = generation
        chain.player.stop()
        if let eqPreset { chain.scheduler.apply(preset: eqPreset) }
        chain.scheduler.eq.globalGain = Float(activeBoostDB)
        startEngineIfNeeded()
        source.beginScheduling(on: chain.player) { [weak self] in
            DispatchQueue.main.async { self?.chainFinished(chain, generation: generation) }
        }
        applyEffectiveVolume()
        if startNode { chain.player.play() }
        log.info("play node: engineRunning=\(self.engine.isRunning, privacy: .public) nodePlaying=\(chain.player.isPlaying, privacy: .public) vol=\(chain.player.volume, privacy: .public) mixerOut=\(self.engine.mainMixerNode.outputVolume, privacy: .public)")
    }

    private func chainFinished(_ chain: Chain, generation: Int) {
        guard chain.generation == generation, chain === active else { return }
        if transition == .crossfading {
            // The incoming track takes over when it is ready (startIncoming).
            outgoingEndedDuringTransition = true
            return
        }
        if startPending {
            // A new start or seek is loading and will replace this chain.
            // Advancing the queue here as well would skip a track.
            activeEndedWhilePending = true
            return
        }
        trackFinished()
    }

    private func trackFinished() {
        if sleepTimer.stopsAtEndOfTrack {
            sleepTimer.cancel()
            publishSleepTimer()
            parkAtNextTrack()
            return
        }
        guard let next = queue.advance() else { stop(); return }
        startPlayback(of: next)
    }

    /// End-of-track sleep timer: the track has played out. Leave the queue on
    /// the next track, paused, so "play" tomorrow carries on from there.
    private func parkAtNextTrack() {
        let finishedAt = currentTime
        guard let next = queue.advance() else { stop(); return }
        intendsToPlay = false
        _ = bumpStartGeneration()
        active.source?.stop()
        active.player.stop()
        active.source = nil
        report(reporter.stopped(at: finishedAt))
        setCurrentTime(0)
        stateModel?.quality = nil
        publish(state: .paused(trackID: next.id), track: next)
        publishQueue()
    }

    private func stop() {
        let position = currentTime
        intendsToPlay = false
        _ = bumpStartGeneration()   // a start that is still loading must not begin after the stop
        active.source?.stop()
        idle.source?.stop()
        active.player.stop()
        idle.player.stop()
        active.source = nil
        idle.source = nil
        transition = .none
        incomingTrack = nil
        incomingPlan = nil
        crossfadeGeneration += 1
        report(reporter.stopped(at: position))
        publish(state: .idle, track: nil)
        stateModel?.upNext = []
        stateModel?.history = []
        stateModel?.quality = nil
        setCurrentTime(0)
        // Keep ticking only while a sleep timer still has to count down.
        if !sleepTimer.isActive { stopTicker() }
    }

    // MARK: - Crossfade / preload (driven by the ticker)

    private func tick() {
        tickSleepTimer()
        guard !startPending, let duration = active.source?.duration, duration > 0 else { return }
        let position = currentSeconds(of: active)
        setCurrentTime(min(position, duration))
        guard intendsToPlay else { return }
        report(reporter.playbackTick(position: currentTime, isPaused: false, now: monotonicNow))

        if transition == .crossfading { driveCrossfade(); return }
        guard let current = queue.currentTrack, let next = queue.nextTrack, next.id != current.id,
              duration > 1,
              // "Stop at end of track" needs the track to end on its own.
              !sleepTimer.stopsAtEndOfTrack,
              next.id != failedIncomingTrackID else { return }
        let remaining = duration - position
        let overlap = fadePlanner.decision(outgoing: current, incoming: next, trailingSilence: 0, isManualSkip: false).overlap
        if overlap > 0, remaining <= overlap {
            beginCrossfade(to: next, overlap: overlap)
        }
    }

    private func beginCrossfade(to next: Track, overlap: TimeInterval) {
        transition = .crossfading
        incomingTrack = next
        let stage = gainStage(forQueueIndex: queue.nextTrackIndex)
        incomingLoudness = Float(stage.volume)
        incomingBoostDB = stage.boostDB
        crossfadeOverlap = overlap
        crossfadeStart = 0   // set once the incoming chain actually starts
        outgoingEndedDuringTransition = false
        crossfadeGeneration += 1
        let fadeGeneration = crossfadeGeneration
        let generation = startGeneration
        let plan = streamPlan(for: next)
        Task { [weak self] in
            guard let self else { return }
            let source = await self.makeSource(plan: plan, startTime: 0)
            await self.startIncoming(generation: generation, fadeGeneration: fadeGeneration, plan: plan, source: source, overlap: overlap)
        }
    }

    @MainActor
    private func startIncoming(generation: Int, fadeGeneration: Int, plan: StreamPlan, source: StreamingAudioSource?, overlap: TimeInterval) {
        guard transition == .crossfading, startGeneration == generation, crossfadeGeneration == fadeGeneration else {
            source?.stop()
            return
        }
        let next = plan.track
        guard let source else {
            // Do not retry this track as a crossfade on every tick; the
            // regular start path picks it up when the outgoing track ends.
            failedIncomingTrackID = next.id
            let outgoingEnded = outgoingEndedDuringTransition
            cancelTransition()
            if outgoingEnded { trackFinished() }
            return
        }
        let chain = idle
        chain.source?.stop()
        chain.source = source
        chain.startOffset = 0
        chain.lastPosition = 0
        let generation = chain.generation + 1
        chain.generation = generation
        chain.player.stop()
        chain.player.volume = 0
        if let eqPreset { chain.scheduler.apply(preset: eqPreset) }
        chain.scheduler.eq.globalGain = Float(incomingBoostDB)
        startEngineIfNeeded()
        source.beginScheduling(on: chain.player) { [weak self] in
            DispatchQueue.main.async { self?.chainFinished(chain, generation: generation) }
        }
        // Paused while the incoming track loaded: play() starts both nodes.
        if intendsToPlay { chain.player.play() }
        incomingPlan = plan
        crossfadeStart = monotonicNow
        log.info("crossfade → \"\(next.title, privacy: .public)\" over \(overlap, privacy: .public)s")
        if outgoingEndedDuringTransition {
            // Nothing left to fade out of — hand over at once instead of
            // fading the new track in from silence.
            finishCrossfade()
        }
    }

    private func driveCrossfade() {
        guard crossfadeStart > 0 else { return }
        let progress = crossfadeOverlap > 0 ? (monotonicNow - crossfadeStart) / crossfadeOverlap : 1
        let fade = Float(sleepTimer.fadeGain(now: monotonicNow))
        active.player.volume = clamp(masterVolume * loudnessGain * fade * Float(CrossfadeCurve.fadeOutGain(progress: progress)))
        idle.player.volume = clamp(masterVolume * incomingLoudness * fade * Float(CrossfadeCurve.fadeInGain(progress: progress)))
        if progress >= 1 { finishCrossfade() }
    }

    private func finishCrossfade() {
        guard transition == .crossfading, let next = incomingTrack else { return }
        let outgoingPosition = currentTime
        active.source?.stop()
        active.player.stop()
        active.source = nil
        activeIsA.toggle()
        loudnessGain = incomingLoudness
        activeBoostDB = incomingBoostDB
        transition = .none
        incomingTrack = nil
        outgoingEndedDuringTransition = false
        crossfadeGeneration += 1
        _ = queue.advance()
        if queue.currentTrack?.id != next.id {
            log.error("queue and crossfade disagree on the current track")
        }
        failurePolicy.recordSuccess()
        applyEffectiveVolume()
        if let plan = incomingPlan {
            currentPlayMethod = plan.playMethod
            stateModel?.quality = plan.quality
        }
        incomingPlan = nil
        setCurrentTime(currentSeconds(of: active))
        publish(state: .playing(trackID: next.id), track: next)
        publishQueue()
        report(reporter.trackStarted(id: next.id, at: 0, previousPosition: outgoingPosition))
        requestLoudness()
        log.info("crossfade complete → \"\(next.title, privacy: .public)\"")
    }

    private func cancelTransition() {
        guard transition != .none else { return }
        idle.source?.stop()
        idle.player.stop()
        idle.source = nil
        transition = .none
        incomingTrack = nil
        incomingPlan = nil
        outgoingEndedDuringTransition = false
        crossfadeGeneration += 1
        applyEffectiveVolume()
    }

    /// The queue changed. If a crossfade is under way into a track that is no
    /// longer next (removed, reordered, repeat mode changed, something queued
    /// in front), drop it — otherwise the audio and the queue would disagree
    /// about what is playing. The ticker starts a new one if still due.
    private func queueEdited() {
        guard transition == .crossfading, queue.nextTrack?.id != incomingTrack?.id else { return }
        cancelTransition()
    }

    // MARK: - Engine recovery

    @objc private func engineConfigurationChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.recoverFromEngineStop(reason: "configuration change") }
    }

    @objc private func mediaServicesWereReset(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // The audio server restarted: the session configuration is gone.
            self.sessionActivated = false
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            self.engine.stop()
            self.recoverFromEngineStop(reason: "media services reset")
        }
    }

    /// The system stops the engine when the output hardware changes (route
    /// switch, sample-rate change). Rebuild the current track where it was —
    /// the same path a seek takes — which also restarts the engine.
    private func recoverFromEngineStop(reason: String) {
        guard !engine.isRunning else { return }
        // The mixer's output format may have changed; the tap is re-installed
        // against the new one when the engine starts again.
        spectrumTap.remove(from: engine.mainMixerNode)
        let now = monotonicNow
        guard now - lastEngineRecovery > 1 else { return }   // never loop on a flapping route
        guard queue.currentTrack != nil, active.source != nil, !startPending else { return }
        lastEngineRecovery = now
        log.info("engine stopped (\(reason, privacy: .public)) — rebuilding at \(self.currentTime, privacy: .public)s")
        restartCurrentTrack(at: currentTime)
    }

    // MARK: - Loudness

    private func gainStage(forQueueIndex index: Int?) -> GainStage {
        guard settings.loudnessLevelingEnabled, let index else {
            return leveler.stage(for: nil, preampDB: settings.loudnessPreampDB)
        }
        let gain = leveler.gain(
            at: index,
            in: queue.tracks,
            measured: { self.measuredLoudness[$0] },
            albumGainDB: { self.albumGains[$0] }
        )
        return leveler.stage(for: gain, preampDB: settings.loudnessPreampDB)
    }

    /// Re-evaluates the playing track's gain (settings changed, or loudness
    /// data arrived after it started).
    private func refreshActiveLoudness() {
        guard queue.currentTrack != nil else { return }
        let stage = gainStage(forQueueIndex: queue.currentIndex)
        loudnessGain = Float(stage.volume)
        activeBoostDB = stage.boostDB
        active.scheduler.eq.globalGain = Float(stage.boostDB)
        applyEffectiveVolume()
        if transition == .crossfading {
            let incoming = gainStage(forQueueIndex: queue.nextTrackIndex)
            incomingLoudness = Float(incoming.volume)
            incomingBoostDB = incoming.boostDB
        }
    }

    /// Fetches what leveling still lacks for the current track, its album
    /// neighbours and the next track, so gains are ready before a transition.
    private func requestLoudness() {
        guard settings.loudnessLevelingEnabled, let index = queue.currentIndex else { return }
        let tracks = queue.tracks
        var wanted = Array(tracks[leveler.albumRun(in: tracks, around: index)].prefix(40))
        if let next = queue.nextTrack { wanted.append(next) }

        if let lookup = loudnessLookup {
            for track in wanted where track.normalizationGainDB == nil
                && measuredLoudness[track.id] == nil && !loudnessRequested.contains(track.id) {
                loudnessRequested.insert(track.id)
                let trackID = track.id
                Task { [weak self] in
                    let measured = await lookup(trackID)
                    await self?.loudnessArrived(measured, forTrack: trackID)
                }
            }
        }
        if let lookup = albumGainLookup, leveler.albumRun(in: tracks, around: index).count > 1,
           let albumID = tracks[index].albumID, !albumGainRequested.contains(albumID) {
            albumGainRequested.insert(albumID)
            Task { [weak self] in
                let gain = await lookup(albumID)
                await self?.albumGainArrived(gain, forAlbum: albumID)
            }
        }
    }

    @MainActor
    private func loudnessArrived(_ measured: MeasuredLoudness?, forTrack trackID: String) {
        guard let measured else {
            // Unknown for now; allow another attempt later (the provider may
            // only become available once the sonic server is configured).
            loudnessRequested.remove(trackID)
            return
        }
        measuredLoudness[trackID] = measured
        refreshActiveLoudness()
    }

    @MainActor
    private func albumGainArrived(_ gain: Double?, forAlbum albumID: String) {
        guard let gain else { return }
        albumGains[albumID] = gain
        refreshActiveLoudness()
    }

    // MARK: - Helpers

    private func currentSeconds(of chain: Chain) -> TimeInterval {
        guard let nodeTime = chain.player.lastRenderTime,
              let playerTime = chain.player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return chain.lastPosition }
        // Silence compression drops buffers the node never sees; add them
        // back so this is the position in the file (0 when the feature is off).
        let position = chain.startOffset + Double(playerTime.sampleTime) / playerTime.sampleRate
            + (chain.source?.skippedSeconds ?? 0)
        chain.lastPosition = position
        return position
    }

    private func setCurrentTime(_ time: TimeInterval) {
        currentTime = time
        // Publishing an unchanged value would still redraw every observer.
        if let model = stateModel, abs(model.currentTime - time) > 0.01 {
            model.currentTime = time
        }
    }

    private func applyEffectiveVolume() {
        guard transition != .crossfading else { return }
        let fade = Float(sleepTimer.fadeGain(now: monotonicNow))
        active.player.volume = clamp(masterVolume * loudnessGain * fade)
    }

    private func clamp(_ value: Float) -> Float { max(0, min(1, value)) }

    /// Decides, on the main thread, how a track will be fetched: a finished
    /// download wins; otherwise direct play or a capped transcode depending
    /// on codec, bitrate and the *current* network type.
    private func streamPlan(for track: Track) -> StreamPlan {
        let localURL = DownloadStore.localURL(for: track)
        let network = NetworkPathObserver.shared.current
        let request = settings.playbackProfile.profile.request(for: track, network: network)
        let quality = AudioQualityInfo(track: track, request: request, isDownloaded: localURL != nil)
        return StreamPlan(
            track: track,
            localURL: localURL,
            request: request,
            quality: quality,
            silenceGate: settings.silenceCompressionEnabled ? SilenceGate() : nil
        )
    }

    /// Builds a streaming source for a track: a downloaded file plays
    /// locally; otherwise progressive remote first, and for direct play, if
    /// that can't start, a cached full download read locally.
    private func makeSource(plan: StreamPlan, startTime: TimeInterval) async -> StreamingAudioSource? {
        let track = plan.track
        let duration = track.duration
        let hint = Self.fileTypeHint(for: track.container)
        let outputFormat = engineFormat
        log.info("makeSource \"\(track.title, privacy: .public)\" container=\(track.container ?? "nil", privacy: .public) codec=\(track.codec ?? "nil", privacy: .public) start=\(startTime, privacy: .public)")
        if let offline = plan.localURL,
           let local = await StreamingAudioSource.make(url: offline, startTime: startTime, duration: duration, fileTypeHint: hint,
                                                        outputFormat: outputFormat, silenceGate: plan.silenceGate) {
            return local
        }
        switch plan.request {
        case .directPlay:
            let remote = StreamURLBuilder.url(for: track.id, request: .directPlay, session: session)
            if let streamed = await StreamingAudioSource.make(url: remote, startTime: startTime, duration: duration, fileTypeHint: hint,
                                                              outputFormat: outputFormat, silenceGate: plan.silenceGate) {
                return streamed
            }
            log.info("progressive read unavailable; falling back to cached download for \(track.title, privacy: .public)")
            guard let cached = try? await cache.localFile(for: track.id, remoteURL: remote) else { return nil }
            return await StreamingAudioSource.make(url: cached, startTime: startTime, duration: duration, fileTypeHint: hint,
                                                   outputFormat: outputFormat, silenceGate: plan.silenceGate)
        case .transcode:
            // A progressive MP3 from the server (the stream parser cannot
            // read the HLS playlist the AVPlayer URL points at). It is not
            // byte-seekable: the server starts encoding at `startTime`, and
            // the source reads that stream from its first byte.
            let remote = StreamURLBuilder.progressiveURL(for: track.id, request: plan.request, startTime: startTime, session: session)
            return await StreamingAudioSource.make(url: remote, startTime: 0, duration: duration, fileTypeHint: kAudioFileMP3Type,
                                                   outputFormat: outputFormat, silenceGate: plan.silenceGate)
        }
    }

    private static func fileTypeHint(for container: String?) -> AudioFileTypeID {
        // Jellyfin reports MP4-family files as "mov,mp4,m4a,3gp,3g2,mj2".
        switch AudioContainer.canonical(container) {
        case "mp3": return kAudioFileMP3Type
        case "aac", "adts": return kAudioFileAAC_ADTSType
        case "m4a", "m4b", "mp4", "alac": return kAudioFileM4AType
        case "flac": return kAudioFileFLACType
        case "wav": return kAudioFileWAVEType
        case "aif", "aiff": return kAudioFileAIFFType
        default: return 0
        }
    }

    private func bumpStartGeneration() -> Int {
        startGeneration += 1
        // Whatever was loading is now stale and will be discarded.
        startPending = false
        pendingIsNewTrack = false
        activeEndedWhilePending = false
        return startGeneration
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        // The engine only stops underneath us after an interruption, a route
        // change or a media-services reset — all of which can leave the
        // session inactive, so the cached "activated" flag cannot be trusted.
        sessionActivated = false
        activateSession()        // engine can only start against an active session
        engine.prepare()         // re-evaluate the output format now the session is active
        do {
            try engine.start()
            log.info("engine started: isRunning=\(self.engine.isRunning, privacy: .public)")
        } catch {
            log.error("engine.start failed: \(error.localizedDescription, privacy: .public)")
        }
        if engine.isRunning, spectrumConsumers > 0 {
            spectrumTap.install(on: engine.mainMixerNode)
        }
    }

    private func activateSession() {
        guard !sessionActivated else { return }
        do { try AVAudioSession.sharedInstance().setActive(true); sessionActivated = true }
        catch { log.error("setActive failed: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: - Ticker

    private func startTicker() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tickSleepTimer() {
        guard sleepTimer.isActive else { return }
        if sleepTimer.shouldStop(now: monotonicNow) {
            // Pause rather than stop: the queue and position survive, so
            // "play" in the morning resumes where the timer faded out.
            sleepTimer.cancel()
            cancelTransition()
            pause()
            applyEffectiveVolume()   // back to full level for the resume
            publishSleepTimer()
            if queue.currentTrack == nil { stopTicker() }
            return
        }
        if transition != .crossfading { applyEffectiveVolume() }
        publishSleepTimer()
    }

    // MARK: - Reporting

    private func report(_ reports: [PlaybackReport]) {
        guard !reports.isEmpty else { return }
        reportSender.send(reports, playMethod: currentPlayMethod)
    }

    /// Pause / resume / seek: an immediate progress report.
    private func reportStateChange() {
        report(reporter.stateChanged(position: currentTime, isPaused: !intendsToPlay, now: monotonicNow))
    }

    // MARK: - Publishing

    private func publishQueue() {
        stateModel?.upNext = queue.upNext
        stateModel?.history = queue.history
    }

    private func publishSleepTimer() {
        let active = sleepTimer.isActive
        let remaining = sleepTimer.remaining(now: monotonicNow)
        if stateModel?.sleepTimerActive != active { stateModel?.sleepTimerActive = active }
        // The countdown is shown to the second; do not republish every tick.
        if stateModel?.sleepTimerRemaining.map({ $0.rounded() }) != remaining.map({ $0.rounded() }) {
            stateModel?.sleepTimerRemaining = remaining
        }
    }

    private func publishShuffleRepeat() {
        // The user's choice, not the queue's flag: a one-track queue cannot
        // shuffle, but the toggle must still show what the next queue will do.
        if stateModel?.isShuffled != shuffleEnabled { stateModel?.isShuffled = shuffleEnabled }
        if stateModel?.repeatMode != preferredRepeatMode { stateModel?.repeatMode = preferredRepeatMode }
    }

    private func publish(state newState: PlaybackState, track: Track?) {
        state = newState
        stateModel?.currentTrack = track
        if case .playing = newState { stateModel?.isPlaying = true } else { stateModel?.isPlaying = false }
        if case .loading = newState { stateModel?.isLoading = true } else { stateModel?.isLoading = false }
        if case .failed(_, let message) = newState { stateModel?.errorMessage = message } else { stateModel?.errorMessage = nil }
    }
}
