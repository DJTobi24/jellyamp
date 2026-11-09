import Foundation
import Combine
import Network
import JellyampCore

/// Source of network path changes. Injectable so the offline logic can be
/// driven without a real network (`NWPathMonitor` in production).
protocol NetworkPathMonitoring: AnyObject {
    /// Starts monitoring; `onChange` may be called on any thread.
    func start(onChange: @escaping @Sendable (_ isSatisfied: Bool, _ isExpensive: Bool) -> Void)
}

final class SystemNetworkPathMonitor: NetworkPathMonitoring {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.djtobi.Jellyamp.network-path")

    func start(onChange: @escaping @Sendable (_ isSatisfied: Bool, _ isExpensive: Bool) -> Void) {
        monitor.pathUpdateHandler = { path in
            onChange(path.status == .satisfied, path.isExpensive)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

/// Observable "are we offline, and why" for the UI (banner, settings).
/// The decision itself lives in `OfflineStateTracker` (JellyampCore), which
/// the `OfflineLibrary` decorator feeds with request outcomes.
@MainActor
final class OfflineStatus: ObservableObject {
    /// Nil while the server is reachable and offline mode is off.
    @Published private(set) var reason: OfflineReason?
    /// Cellular or personal hotspot.
    @Published private(set) var isExpensive = false

    var isOffline: Bool { reason != nil }

    let tracker: OfflineStateTracker
    private let monitor: NetworkPathMonitoring

    init(tracker: OfflineStateTracker = OfflineStateTracker(), monitor: NetworkPathMonitoring = SystemNetworkPathMonitor()) {
        self.tracker = tracker
        self.monitor = monitor
        tracker.observe { [weak self] _ in
            // Read the tracker again on the main actor instead of trusting the
            // order in which these hops arrive.
            Task { @MainActor in self?.refresh() }
        }
        monitor.start { [tracker] isSatisfied, isExpensive in
            tracker.setNetworkPath(isSatisfied: isSatisfied, isExpensive: isExpensive)
        }
        refresh()
    }

    private func refresh() {
        let snapshot = tracker.snapshot
        if reason != snapshot.reason { reason = snapshot.reason }
        if isExpensive != snapshot.isExpensive { isExpensive = snapshot.isExpensive }
    }
}
