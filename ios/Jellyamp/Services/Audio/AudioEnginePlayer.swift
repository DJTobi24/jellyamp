import Foundation
import AVFoundation
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
/// The simpler `EnginePlayer` (AVPlayer) stays as a one-line fallback in
/// `DependencyContainer`.
final class AudioEnginePlayer: NSObject, PlayerEngine, ObservableObject {
    @Published private(set) var state: PlaybackState = .idle
    private(set) var currentTime: TimeInterval = 0

    private final class Chain {
        let scheduler: TrackSchedulerNode
        var source: StreamingAudioSource?
        var startOffset: TimeInterval = 0
        var generation = 0
        var player: AVAudioPlayerNode { scheduler.player }
        init(engine: AVAudioEngine) {
            scheduler = TrackSchedulerNode(engine: engine)
            scheduler.attach(to: engine)
        }
    }

    private let engine = AVAudioEngine()
    private let chainA: Chain
    private let chainB: Chain
    private var activeIsA = true
    private var active: Chain { activeIsA ? chainA : chainB }
    private var idle: Chain { activeIsA ? chainB : chainA }

    private let session: JellyfinSession
    private var settings: AppSettings
    private var queue = PlayQueue()
    private var reporter = PlaybackReporter()
    private let reporting: PlaybackReportingAPI
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

    private var ticker: Timer?
    private var startGeneration = 0

    private let log = Logger(subsystem: "dev.djtobi.Jellyamp", category: "Playback")

    init(session: JellyfinSession, settings: AppSettings, stateModel: PlayerStateModel) {
        self.session = session
        self.settings = settings
        self.reporting = PlaybackReportingAPI(session: session)
        self.cache = StreamingAssetCache(session: session)
        self.stateModel = stateModel
        self.sleepTimer = SleepTimer(fadeOutDuration: settings.sleepTimerFadeOut)
        self.fadePlanner = SweetFadePlanner(fadeDuration: settings.crossfadeDuration)
        self.chainA = Chain(engine: engine)
        self.chainB = Chain(engine: engine)
        super.init()
        engine.prepare()
        log.info("AudioEnginePlayer init (progressive streaming)")
    }

    deinit { ticker?.invalidate() }

    // MARK: - PlayerEngine

    func load(queue: PlayQueue) {
        var queue = queue
        queue.setRepeatMode(preferredRepeatMode)
        if shuffleEnabled { queue.shuffle() }
        self.queue = queue
        guard let track = queue.currentTrack else { return }
        startPlayback(of: track)
    }

    func play() {
        intendsToPlay = true
        activateSession()
        startEngineIfNeeded()
        active.player.play()
        if transition == .crossfading { idle.player.play() }
        publish(state: .playing(trackID: queue.currentTrack?.id ?? ""), track: queue.currentTrack)
        startTicker()
    }

    func pause() {
        intendsToPlay = false
        active.player.pause()
        idle.player.pause()
        publish(state: .paused(trackID: queue.currentTrack?.id ?? ""), track: queue.currentTrack)
    }

    func seek(to time: TimeInterval) {
        guard let track = queue.currentTrack else { return }
        cancelTransition()
        let generation = bumpStartGeneration()
        currentTime = time
        Task { [weak self] in
            guard let self else { return }
            let source = await self.makeSource(for: track, startTime: time)
            await self.finishStart(generation: generation, track: track, source: source, startOffset: time)
        }
    }

    func skipToNext() {
        guard let next = queue.skipToNext() else { return }
        startPlayback(of: next)
    }

    func skipToPrevious() {
        guard let previous = queue.skipToPrevious() else { return }
        startPlayback(of: previous)
    }

    func setVolume(_ volume: Double) {
        masterVolume = Float(volume)
        applyEffectiveVolume()
    }

    func enqueue(_ tracks: [Track]) {
        let wasIdle = queue.currentTrack == nil
        queue.append(tracks)
        publishQueue()
        if wasIdle, let track = queue.currentTrack { startPlayback(of: track) }
    }

    func playNext(_ tracks: [Track]) {
        let wasIdle = queue.currentTrack == nil
        queue.insertNext(tracks)
        publishQueue()
        if wasIdle, let track = queue.currentTrack { startPlayback(of: track) }
    }

    func playUpNext(at upNextIndex: Int) {
        let absolute = (queue.currentIndex ?? -1) + 1 + upNextIndex
        queue.jump(to: absolute)
        guard let track = queue.currentTrack else { return }
        startPlayback(of: track)
    }

    func removeUpNext(at upNextIndex: Int) {
        let absolute = (queue.currentIndex ?? -1) + 1 + upNextIndex
        queue.remove(at: absolute)
        publishQueue()
    }

    func moveUpNext(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let from = source.first else { return }
        let base = (queue.currentIndex ?? -1) + 1
        queue.move(from: base + from, to: base + (destination > from ? destination - 1 : destination))
        publishQueue()
    }

    func setShuffle(_ enabled: Bool) {
        shuffleEnabled = enabled
        if enabled { queue.shuffle() } else { queue.unshuffle() }
        publishQueue()
        publishShuffleRepeat()
    }

    func cycleRepeatMode() {
        switch queue.repeatMode {
        case .off: preferredRepeatMode = .all
        case .all: preferredRepeatMode = .one
        case .one: preferredRepeatMode = .off
        }
        queue.setRepeatMode(preferredRepeatMode)
        publishShuffleRepeat()
    }

    func playShuffled(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        shuffleEnabled = true
        var fresh = PlayQueue(tracks: tracks, startAt: Int.random(in: 0..<tracks.count))
        fresh.setRepeatMode(preferredRepeatMode)
        fresh.shuffle()
        queue = fresh
        if let track = queue.currentTrack { startPlayback(of: track) }
        publishShuffleRepeat()
    }

    func apply(eqPreset: EQPreset) {
        self.eqPreset = eqPreset
        chainA.scheduler.apply(preset: eqPreset)
        chainB.scheduler.apply(preset: eqPreset)
    }

    func updateSettings(_ newSettings: AppSettings) {
        settings = newSettings
        fadePlanner.fadeDuration = newSettings.crossfadeDuration
    }

    func startSleepTimer(duration: TimeInterval?) {
        if let duration { sleepTimer.start(duration: duration, now: monotonicNow) }
        else { sleepTimer.startEndOfTrack() }
        publishSleepTimer()
    }

    func cancelSleepTimer() {
        sleepTimer.cancel()
        applyEffectiveVolume()
        publishSleepTimer()
    }

    // MARK: - Playback

    private func startPlayback(of track: Track) {
        cancelTransition()
        intendsToPlay = true
        loudnessGain = gain(for: track)
        publish(state: .loading(trackID: track.id), track: track)
        publishQueue()
        publishShuffleRepeat()
        let generation = bumpStartGeneration()
        Task { [weak self] in
            guard let self else { return }
            let source = await self.makeSource(for: track, startTime: 0)
            await self.finishStart(generation: generation, track: track, source: source, startOffset: 0)
        }
    }

    @MainActor
    private func finishStart(generation: Int, track: Track, source: StreamingAudioSource?, startOffset: TimeInterval) {
        guard startGeneration == generation else { source?.stop(); return }
        guard let source else {
            publish(state: .failed(trackID: track.id, message: "Couldn't load track."), track: track)
            return
        }
        play(track, source: source, on: active, startOffset: startOffset)
        publish(state: .playing(trackID: track.id), track: track)
        startTicker()
        sendStartReports(for: track)
    }

    /// Attaches a source to a chain and starts the node.
    private func play(_ track: Track, source: StreamingAudioSource, on chain: Chain, startOffset: TimeInterval) {
        activateSession()
        startEngineIfNeeded()
        chain.source?.stop()
        chain.source = source
        chain.startOffset = startOffset
        let generation = chain.generation + 1
        chain.generation = generation
        chain.player.stop()
        engine.connect(chain.player, to: chain.scheduler.eq, format: source.format)
        if let eqPreset { chain.scheduler.apply(preset: eqPreset) }
        startEngineIfNeeded()
        source.beginScheduling(on: chain.player) { [weak self] in
            DispatchQueue.main.async { self?.chainFinished(chain, generation: generation) }
        }
        applyEffectiveVolume()
        chain.player.play()
    }

    private func chainFinished(_ chain: Chain, generation: Int) {
        guard chain.generation == generation, chain === active, transition == .none else { return }
        trackFinished()
    }

    private func trackFinished() {
        if case .endOfTrack = sleepTimer.mode {
            sleepTimer.cancel(); publishSleepTimer(); stop(); return
        }
        guard let next = queue.advance() else { stop(); return }
        startPlayback(of: next)
    }

    private func stop() {
        intendsToPlay = false
        active.source?.stop()
        idle.source?.stop()
        active.player.stop()
        idle.player.stop()
        publish(state: .idle, track: nil)
        stateModel?.upNext = []
        stopTicker()
    }

    // MARK: - Crossfade / preload (driven by the ticker)

    private func tick() {
        guard let duration = active.source?.duration, duration > 0 else { return }
        let position = currentSeconds(of: active)
        currentTime = min(position, duration)
        stateModel?.currentTime = currentTime
        tickSleepTimer()

        if transition == .crossfading { driveCrossfade(); return }
        guard intendsToPlay, transition == .none,
              let current = queue.currentTrack, let next = queue.nextTrack, next.id != current.id,
              duration > 1 else { return }
        let remaining = duration - position
        let overlap = fadePlanner.decision(outgoing: current, incoming: next, trailingSilence: 0, isManualSkip: false).overlap
        if overlap > 0, remaining <= overlap {
            beginCrossfade(to: next, overlap: overlap)
        }
    }

    private func beginCrossfade(to next: Track, overlap: TimeInterval) {
        transition = .crossfading
        incomingTrack = next
        incomingLoudness = gain(for: next)
        crossfadeOverlap = overlap
        crossfadeStart = 0   // set once the incoming chain actually starts
        let generation = startGeneration
        Task { [weak self] in
            guard let self else { return }
            let source = await self.makeSource(for: next, startTime: 0)
            await self.startIncoming(generation: generation, next: next, source: source, overlap: overlap)
        }
    }

    @MainActor
    private func startIncoming(generation: Int, next: Track, source: StreamingAudioSource?, overlap: TimeInterval) {
        guard transition == .crossfading, startGeneration == generation else { source?.stop(); return }
        guard let source else { cancelTransition(); return }
        let chain = idle
        chain.source?.stop()
        chain.source = source
        chain.startOffset = 0
        let generation = chain.generation + 1
        chain.generation = generation
        chain.player.stop()
        chain.player.volume = 0
        engine.connect(chain.player, to: chain.scheduler.eq, format: source.format)
        if let eqPreset { chain.scheduler.apply(preset: eqPreset) }
        startEngineIfNeeded()
        source.beginScheduling(on: chain.player) { [weak self] in
            DispatchQueue.main.async { self?.chainFinished(chain, generation: generation) }
        }
        chain.player.play()
        crossfadeStart = monotonicNow
        log.info("crossfade → \"\(next.title, privacy: .public)\" over \(overlap, privacy: .public)s")
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
        active.source?.stop()
        active.player.stop()
        active.source = nil
        activeIsA.toggle()
        loudnessGain = incomingLoudness
        transition = .none
        incomingTrack = nil
        _ = queue.advance()
        applyEffectiveVolume()
        publish(state: .playing(trackID: next.id), track: next)
        publishQueue()
        sendStartReports(for: next)
        log.info("crossfade complete → \"\(next.title, privacy: .public)\"")
    }

    private func cancelTransition() {
        guard transition != .none else { return }
        idle.source?.stop()
        idle.player.stop()
        idle.source = nil
        transition = .none
        incomingTrack = nil
        applyEffectiveVolume()
    }

    // MARK: - Helpers

    private func currentSeconds(of chain: Chain) -> TimeInterval {
        guard let nodeTime = chain.player.lastRenderTime,
              let playerTime = chain.player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return chain.startOffset }
        return chain.startOffset + Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    private func applyEffectiveVolume() {
        guard transition != .crossfading else { return }
        let fade = Float(sleepTimer.fadeGain(now: monotonicNow))
        active.player.volume = clamp(masterVolume * loudnessGain * fade)
    }

    private func clamp(_ value: Float) -> Float { max(0, min(1, value)) }

    private func gain(for track: Track) -> Float {
        Float(LoudnessMath.playbackGain(
            normalizationGainDB: settings.loudnessLevelingEnabled ? track.normalizationGainDB : nil,
            preampDB: settings.loudnessPreampDB))
    }

    /// Builds a streaming source for a track: progressive remote first; if that
    /// can't start, fall back to a cached download and read that locally.
    /// Offline downloads play straight from the local file.
    private func makeSource(for track: Track, startTime: TimeInterval) async -> StreamingAudioSource? {
        let duration = track.duration
        if let offline = DownloadStore.localURL(for: track) {
            return await StreamingAudioSource.make(url: offline, startTime: startTime, duration: duration)
        }
        let request = settings.playbackProfile.profile.request(for: track, network: .wifi)
        let remote = StreamURLBuilder.url(for: track.id, request: request, session: session)
        if let streamed = await StreamingAudioSource.make(url: remote, startTime: startTime, duration: duration) {
            return streamed
        }
        log.info("progressive read unavailable; falling back to cached download for \(track.title, privacy: .public)")
        guard let cached = try? await cache.localFile(for: track.id, remoteURL: remote) else { return nil }
        return await StreamingAudioSource.make(url: cached, startTime: startTime, duration: duration)
    }

    private func bumpStartGeneration() -> Int { startGeneration += 1; return startGeneration }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        do { try engine.start() } catch { log.error("engine.start failed: \(error.localizedDescription, privacy: .public)") }
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
            sleepTimer.cancel(); cancelTransition(); stop(); publishSleepTimer(); return
        }
        if transition != .crossfading { applyEffectiveVolume() }
        publishSleepTimer()
    }

    // MARK: - Publishing

    private func sendStartReports(for track: Track) {
        Task {
            for report in reporter.trackStarted(id: track.id, at: 0) {
                try? await reporting.send(report, playSessionID: track.id)
            }
        }
    }

    private func publishQueue() { stateModel?.upNext = queue.upNext }

    private func publishSleepTimer() {
        stateModel?.sleepTimerActive = sleepTimer.isActive
        stateModel?.sleepTimerRemaining = sleepTimer.remaining(now: monotonicNow)
    }

    private func publishShuffleRepeat() {
        if stateModel?.isShuffled != queue.isShuffled { stateModel?.isShuffled = queue.isShuffled }
        if stateModel?.repeatMode != queue.repeatMode { stateModel?.repeatMode = queue.repeatMode }
    }

    private func publish(state newState: PlaybackState, track: Track?) {
        state = newState
        stateModel?.currentTrack = track
        if case .playing = newState { stateModel?.isPlaying = true } else { stateModel?.isPlaying = false }
        if case .failed(_, let message) = newState { stateModel?.errorMessage = message } else { stateModel?.errorMessage = nil }
    }
}
