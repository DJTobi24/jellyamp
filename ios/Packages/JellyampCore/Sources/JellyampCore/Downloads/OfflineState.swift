import Foundation

/// Why the app is currently serving the downloaded library instead of the
/// server. Ordered by precedence: an explicit user choice wins.
public enum OfflineReason: String, Equatable, Sendable {
    /// The user switched on offline mode.
    case userEnabled
    /// The device has no network path at all.
    case noNetwork
    /// There is a network, but requests to the server keep failing.
    case serverUnreachable
}

/// Decides whether the library should be served from downloads. Fed by three
/// independent sources — the offline-mode setting, the system's network path
/// (`NWPathMonitor` on device) and the outcome of real requests — so it is
/// right even when the path says "satisfied" but the server is down or only
/// reachable on the home network.
///
/// Thread-safe; request outcomes arrive from arbitrary tasks.
public final class OfflineStateTracker: @unchecked Sendable {
    public struct Snapshot: Equatable, Sendable {
        public var reason: OfflineReason?
        /// Cellular / personal hotspot; used to hold back automatic downloads.
        public var isExpensive: Bool

        public var isOffline: Bool { reason != nil }
    }

    private let lock = NSLock()
    private let now: @Sendable () -> Date
    private let retryInterval: TimeInterval
    private var userEnabled = false
    private var hasNetworkPath = true
    private var isExpensive = false
    private var unreachableSince: Date?
    private var lastProbeAt: Date?
    private var observers: [@Sendable (Snapshot) -> Void] = []

    /// - Parameter retryInterval: while the server is marked unreachable, one
    ///   request is let through this often to notice it coming back.
    public init(retryInterval: TimeInterval = 20, now: @escaping @Sendable () -> Date = { Date() }) {
        self.retryInterval = retryInterval
        self.now = now
    }

    public var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return makeSnapshot()
    }

    public var isOffline: Bool { snapshot.isOffline }

    /// Called with the new state whenever it changes (on the mutating thread).
    public func observe(_ observer: @escaping @Sendable (Snapshot) -> Void) {
        lock.lock()
        observers.append(observer)
        lock.unlock()
    }

    public func setUserEnabled(_ enabled: Bool) {
        mutate { userEnabled = enabled }
    }

    /// Network path update. A path coming (back) up clears the "server
    /// unreachable" verdict so the next request tries the server right away.
    public func setNetworkPath(isSatisfied: Bool, isExpensive expensive: Bool) {
        mutate {
            if isSatisfied, !hasNetworkPath || expensive != isExpensive {
                unreachableSince = nil
                lastProbeAt = nil
            }
            hasNetworkPath = isSatisfied
            isExpensive = expensive
        }
    }

    public func recordRequestSuccess() {
        mutate {
            unreachableSince = nil
            lastProbeAt = nil
        }
    }

    /// A request failed for connectivity reasons (not an HTTP error status).
    public func recordConnectivityFailure() {
        mutate {
            let date = now()
            if unreachableSince == nil { unreachableSince = date }
            lastProbeAt = date
        }
    }

    public enum Route: Equatable, Sendable {
        /// Ask the server.
        case online
        /// Serve from downloads without touching the network.
        case offline
        /// Server is marked unreachable but it is time to check again: ask the
        /// server and fall back to downloads if that fails.
        case probe
    }

    /// How the next library request should be served.
    public func route() -> Route {
        lock.lock()
        defer { lock.unlock() }
        if userEnabled || !hasNetworkPath { return .offline }
        guard unreachableSince != nil else { return .online }
        let date = now()
        if let lastProbeAt, date.timeIntervalSince(lastProbeAt) < retryInterval { return .offline }
        // Claim the probe so concurrent requests don't all hit a dead server.
        lastProbeAt = date
        return .probe
    }

    private func makeSnapshot() -> Snapshot {
        let reason: OfflineReason?
        if userEnabled {
            reason = .userEnabled
        } else if !hasNetworkPath {
            reason = .noNetwork
        } else if unreachableSince != nil {
            reason = .serverUnreachable
        } else {
            reason = nil
        }
        return Snapshot(reason: reason, isExpensive: isExpensive)
    }

    private func mutate(_ body: () -> Void) {
        lock.lock()
        let before = makeSnapshot()
        body()
        let after = makeSnapshot()
        let toNotify = before == after ? [] : observers
        lock.unlock()
        for observer in toNotify { observer(after) }
    }
}
