import Foundation
import AVFAudio
import Combine
import JellyampCore
import JellyfinBackend

/// AVAudioEngine-based player: two alternating node chains for gapless joins
/// and crossfades (see docs/AUDIO-ENGINE.md and ADR-0002).
///
/// Phase-0 scaffold: graph setup, queue handoff, loudness gain, and EQ wiring
/// are in place; progressive streaming hands off to `StreamingAssetCache` and
/// is completed in Phase 1 against a real server.
final class EnginePlayer: NSObject, PlayerEngine, ObservableObject {
    @Published private(set) var state: PlaybackState = .idle
    private(set) var currentTime: TimeInterval = 0

    private let engine = AVAudioEngine()
    private let chainA: TrackSchedulerNode
    private let chainB: TrackSchedulerNode
    /// Chain currently playing the audible track.
    private var activeChain: TrackSchedulerNode

    private let session: JellyfinSession
    private var settings: AppSettings
    private var queue = PlayQueue()
    private var reporter = PlaybackReporter()
    private let reporting: PlaybackReportingAPI
    private let cache: StreamingAssetCache
    private let fadePlanner: SweetFadePlanner

    init(session: JellyfinSession, settings: AppSettings) {
        self.session = session
        self.settings = settings
        self.reporting = PlaybackReportingAPI(session: session)
        self.cache = StreamingAssetCache(session: session)
        self.fadePlanner = SweetFadePlanner(fadeDuration: settings.crossfadeDuration)
        self.chainA = TrackSchedulerNode(engine: engine)
        self.chainB = TrackSchedulerNode(engine: engine)
        self.activeChain = chainA
        super.init()
        chainA.attach(to: engine)
        chainB.attach(to: engine)
    }

    // MARK: - PlayerEngine

    func load(queue: PlayQueue) {
        self.queue = queue
        guard let track = queue.currentTrack else { return }
        state = .loading(trackID: track.id)
        Task { await startPlayback(of: track) }
    }

    func play() {
        guard case .paused(let trackID) = state else { return }
        activeChain.player.play()
        state = .playing(trackID: trackID)
    }

    func pause() {
        guard case .playing(let trackID) = state else { return }
        activeChain.player.pause()
        state = .paused(trackID: trackID)
    }

    func seek(to time: TimeInterval) {
        // Direct-play: reschedule from the target frame using cached bytes.
        // Transcode: new request with startTimeTicks (Phase 1).
        currentTime = time
    }

    func skipToNext() {
        guard let next = queue.skipToNext() else { return }
        crossfade(to: next, isManualSkip: true)
    }

    func skipToPrevious() {
        guard let previous = queue.skipToPrevious() else { return }
        crossfade(to: previous, isManualSkip: true)
    }

    func setVolume(_ volume: Double) {
        engine.mainMixerNode.outputVolume = Float(volume)
    }

    func apply(eqPreset: EQPreset) {
        chainA.apply(preset: eqPreset)
        chainB.apply(preset: eqPreset)
    }

    // MARK: - Internals

    private func startPlayback(of track: Track) async {
        do {
            let profile = settings.playbackProfile.profile
            let request = profile.request(for: track, network: .wifi)
            let url = StreamURLBuilder.url(for: track.id, request: request, session: session)
            let localFile = try await cache.localFile(for: track.id, remoteURL: url)

            if !engine.isRunning {
                try engine.start()
            }
            let gain = LoudnessMath.playbackGain(
                normalizationGainDB: settings.loudnessLevelingEnabled ? track.normalizationGainDB : nil,
                preampDB: settings.loudnessPreampDB
            )
            try activeChain.schedule(file: localFile, gain: Float(gain)) { [weak self] in
                Task { @MainActor in self?.trackFinished() }
            }
            activeChain.player.play()
            await MainActor.run {
                state = .playing(trackID: track.id)
            }
            for report in reporter.trackStarted(id: track.id, at: 0) {
                try? await reporting.send(report, playSessionID: track.id)
            }
        } catch {
            await MainActor.run {
                state = .failed(trackID: track.id, message: error.localizedDescription)
            }
        }
    }

    private func trackFinished() {
        guard let next = queue.advance() else {
            state = .idle
            return
        }
        crossfade(to: next, isManualSkip: false)
    }

    /// Swaps chains, letting `SweetFadePlanner` decide overlap vs gapless join.
    private func crossfade(to track: Track, isManualSkip: Bool) {
        activeChain = (activeChain === chainA) ? chainB : chainA
        state = .loading(trackID: track.id)
        Task { await startPlayback(of: track) }
    }
}
