import Foundation
import Network
import OSLog
import JellyampCore
import JellyfinBackend

/// Current network class for the streaming decision (direct play vs. capped
/// transcode). One process-wide `NWPathMonitor`; reads are thread-safe.
final class NetworkPathObserver: @unchecked Sendable {
    static let shared = NetworkPathObserver()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    // Until the first path update arrives assume Wi-Fi: that is what the
    // engine assumed before it looked at the network at all.
    private var type: NetworkType = .wifi

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let classified = NetworkType.classify(
                isSatisfied: path.status == .satisfied,
                usesCellular: path.usesInterfaceType(.cellular),
                isExpensive: path.isExpensive
            )
            self?.set(classified)
        }
        monitor.start(queue: DispatchQueue(label: "dev.djtobi.Jellyamp.network-path"))
    }

    private func set(_ newType: NetworkType) {
        lock.lock()
        type = newType
        lock.unlock()
    }

    var current: NetworkType {
        lock.lock()
        defer { lock.unlock() }
        return type
    }
}

/// Sends playback reports to Jellyfin strictly in the order they were
/// produced (a stop must not overtake its start). Call `send` from the main
/// thread; delivery happens on a background task and failures are dropped —
/// reporting must never disturb playback.
final class PlaybackReportSender {
    private struct Item {
        let report: PlaybackReport
        let playSessionID: String
        let playMethod: String
    }

    private var ledger = PlaySessionLedger()
    private let continuation: AsyncStream<Item>.Continuation
    private let worker: Task<Void, Never>

    init(api: PlaybackReportingAPI) {
        var captured: AsyncStream<Item>.Continuation?
        let stream = AsyncStream<Item> { captured = $0 }
        // The build closure runs synchronously, so the continuation is set.
        continuation = captured!
        let log = Logger(subsystem: "dev.djtobi.Jellyamp", category: "Reporting")
        worker = Task.detached(priority: .utility) {
            for await item in stream {
                do {
                    try await api.send(item.report, playSessionID: item.playSessionID, playMethod: item.playMethod)
                } catch {
                    log.error("playback report failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    deinit {
        // Lets already queued reports (the final stop) drain, then ends the worker.
        continuation.finish()
    }

    func send(_ reports: [PlaybackReport], playMethod: String) {
        for report in reports {
            let sessionID = ledger.sessionID(for: report)
            continuation.yield(Item(report: report, playSessionID: sessionID, playMethod: playMethod))
        }
    }
}

/// Measured loudness for tracks without a `NormalizationGain` tag: disk cache
/// first, then the sonic server. The engine gets this as a plain closure
/// (`AudioEnginePlayer.loudnessLookup`) and never sees the container.
final class LoudnessService: @unchecked Sendable {
    /// Asks the sonic server. Returns nil when no loudness-capable provider is
    /// configured (not remembered); throws when the server has no value.
    typealias Fetch = @Sendable (_ trackID: String) async throws -> MeasuredLoudness?

    private let cache: LoudnessCache
    private let fetch: Fetch
    private let lock = NSLock()
    /// Tracks the server could not answer for; not asked again this session.
    private var misses: Set<String> = []

    init(fetch: @escaping Fetch, cache: LoudnessCache = LoudnessService.makeDiskCache()) {
        self.fetch = fetch
        self.cache = cache
    }

    static func makeDiskCache() -> LoudnessCache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return LoudnessCache(fileURL: caches.appendingPathComponent("loudness/measured.json"))
    }

    func loudness(forTrack trackID: String) async -> MeasuredLoudness? {
        if let cached = cache.value(for: trackID) { return cached }
        if isKnownMiss(trackID) { return nil }
        do {
            guard let measured = try await fetch(trackID) else { return nil }
            cache.store(measured, for: trackID)
            return measured
        } catch {
            rememberMiss(trackID)
            return nil
        }
    }

    private func isKnownMiss(_ trackID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return misses.contains(trackID)
    }

    private func rememberMiss(_ trackID: String) {
        lock.lock()
        misses.insert(trackID)
        lock.unlock()
    }
}
