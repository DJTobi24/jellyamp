import Foundation

/// Snapshot of the scrobbling pipeline for the settings screen.
public struct ScrobbleStatus: Equatable, Sendable {
    /// Listens waiting to be delivered, per service.
    public var pending: [ScrobbleServiceID: Int]
    /// Most recent delivery problem per service; cleared by a success.
    public var lastError: [ScrobbleServiceID: String]
    /// Services whose credentials were refused and must be reconnected.
    public var needsReauthentication: Set<ScrobbleServiceID>

    public init(
        pending: [ScrobbleServiceID: Int] = [:],
        lastError: [ScrobbleServiceID: String] = [:],
        needsReauthentication: Set<ScrobbleServiceID> = []
    ) {
        self.pending = pending
        self.lastError = lastError
        self.needsReauthentication = needsReauthentication
    }

    public var totalPending: Int { pending.values.reduce(0, +) }
}

/// Delivers scrobble actions to the active services and owns the offline
/// queue: every scrobble is persisted first and removed only once its
/// service accepted it, so nothing is lost offline or across relaunches.
///
/// An actor because playback events, connectivity changes and app
/// foregrounding can all ask for a flush at the same time.
public actor ScrobbleEngine {
    private var queue: ScrobbleQueue
    private let store: ScrobbleQueueStoring
    private let now: @Sendable () -> Date

    private var targets: [ScrobbleServiceID: ScrobbleTarget] = [:]
    private var queueOnly: Set<ScrobbleServiceID> = []
    private var lastError: [ScrobbleServiceID: String] = [:]
    private var needsReauthentication: Set<ScrobbleServiceID> = []
    /// Services that asked to be left alone until a point in time.
    private var notBefore: [ScrobbleServiceID: Date] = [:]
    private var isFlushing = false
    private var flushRequestedWhileBusy = false

    /// Backoff used when a service says "retry later" without saying when.
    public static let defaultRetryDelay: TimeInterval = 60

    public init(
        store: ScrobbleQueueStoring,
        policy: ScrobbleQueuePolicy = ScrobbleQueuePolicy(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
        self.queue = ScrobbleQueue(entries: store.loadPendingScrobbles(), policy: policy)
    }

    /// Replace the set of services to deliver to.
    ///
    /// `queueOnly` lists services that are switched on but cannot deliver at
    /// the moment (session expired, waiting for the user to reconnect):
    /// scrobbles keep being queued for them so the gap can be filled later.
    public func configure(targets newTargets: [ScrobbleTarget], queueOnly: Set<ScrobbleServiceID> = []) -> ScrobbleStatus {
        var byService: [ScrobbleServiceID: ScrobbleTarget] = [:]
        for target in newTargets {
            byService[target.service] = target
        }
        targets = byService
        self.queueOnly = queueOnly.subtracting(byService.keys)
        // A fresh target means fresh credentials: give it a clean slate.
        for service in byService.keys {
            needsReauthentication.remove(service)
            notBefore[service] = nil
        }
        for service in ScrobbleServiceID.allCases where byService[service] == nil && !self.queueOnly.contains(service) {
            lastError[service] = nil
            needsReauthentication.remove(service)
        }
        return status()
    }

    /// Perform the coordinator's actions: now-playing goes out immediately
    /// (best effort, never queued — it is stale within minutes); scrobbles
    /// are queued and the queue is flushed.
    @discardableResult
    public func perform(_ actions: [ScrobbleAction]) async -> ScrobbleStatus {
        var enqueued = false
        for action in actions {
            switch action {
            case .nowPlaying(let listen):
                await sendNowPlaying(listen)
            case .scrobble(let listen):
                let timestamp = now()
                for service in ScrobbleServiceID.allCases where targets[service] != nil || queueOnly.contains(service) {
                    if queue.enqueue(listen, for: service, now: timestamp) {
                        enqueued = true
                    }
                }
            }
        }
        if enqueued {
            persist()
            return await flush()
        }
        return status()
    }

    /// Try to deliver everything that is queued, oldest first, in batches.
    /// `ignoringBackoff` is for explicit user action ("Send now").
    @discardableResult
    public func flush(ignoringBackoff: Bool = false) async -> ScrobbleStatus {
        if isFlushing {
            // Actor methods interleave at awaits; a second concurrent flush
            // would submit the same batch twice. Remember the request so
            // listens queued meanwhile still go out.
            flushRequestedWhileBusy = true
            return status()
        }
        isFlushing = true
        defer { isFlushing = false }

        repeat {
            flushRequestedWhileBusy = false
            if queue.prune(now: now()) > 0 {
                persist()
            }
            for service in ScrobbleServiceID.allCases {
                guard let target = targets[service], !needsReauthentication.contains(service) else { continue }
                if !ignoringBackoff, let earliest = notBefore[service], now() < earliest { continue }
                await flush(service: service, to: target)
            }
        } while flushRequestedWhileBusy

        return status()
    }

    /// Forget a service's queued listens and errors (the user disconnected it).
    public func discardPending(for service: ScrobbleServiceID) -> ScrobbleStatus {
        queue.removeAll(for: service)
        lastError[service] = nil
        needsReauthentication.remove(service)
        notBefore[service] = nil
        persist()
        return status()
    }

    public func status() -> ScrobbleStatus {
        var pending: [ScrobbleServiceID: Int] = [:]
        for service in ScrobbleServiceID.allCases {
            let count = queue.count(for: service)
            if count > 0 { pending[service] = count }
        }
        return ScrobbleStatus(pending: pending, lastError: lastError, needsReauthentication: needsReauthentication)
    }

    // MARK: - Delivery

    private func sendNowPlaying(_ listen: ScrobbleListen) async {
        for service in ScrobbleServiceID.allCases {
            guard let target = targets[service], !needsReauthentication.contains(service) else { continue }
            do {
                try await target.sendNowPlaying(listen)
            } catch let error as ScrobbleDeliveryError {
                // Only a refused credential is worth surfacing; a missed
                // now-playing update is harmless.
                if case .reauthenticate(let message) = error {
                    needsReauthentication.insert(service)
                    lastError[service] = message
                }
            } catch {
                // Offline: the scrobble itself will be queued later.
            }
        }
    }

    private func flush(service: ScrobbleServiceID, to target: ScrobbleTarget) async {
        while true {
            let batch = queue.nextBatch(for: service, limit: max(1, target.maxBatchSize))
            guard !batch.isEmpty else { return }
            let ids = Set(batch.map(\.id))
            do {
                try await target.submit(batch.map(\.listen))
                queue.remove(ids: ids)
                lastError[service] = nil
                notBefore[service] = nil
                persist()
            } catch let error as ScrobbleDeliveryError {
                switch error {
                case .offline:
                    lastError[service] = error.message
                case .retryLater(let delay, let message):
                    queue.recordFailedAttempt(ids: ids)
                    notBefore[service] = now().addingTimeInterval(delay ?? Self.defaultRetryDelay)
                    lastError[service] = message
                    persist()
                case .reauthenticate(let message):
                    needsReauthentication.insert(service)
                    lastError[service] = message
                case .rejected(let message):
                    // Dropping is the only way forward: a refused batch at
                    // the head of the queue would block everything behind it.
                    queue.remove(ids: ids)
                    lastError[service] = message
                    persist()
                    continue
                }
                return
            } catch {
                lastError[service] = ScrobbleDeliveryError.offline.message
                return
            }
        }
    }

    private func persist() {
        store.save(pendingScrobbles: queue.entries)
    }
}

/// In-memory queue store for tests and previews.
public final class InMemoryScrobbleQueueStore: ScrobbleQueueStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [PendingScrobble]

    public init(entries: [PendingScrobble] = []) {
        self.entries = entries
    }

    public func loadPendingScrobbles() -> [PendingScrobble] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public func save(pendingScrobbles: [PendingScrobble]) {
        lock.lock()
        defer { lock.unlock() }
        entries = pendingScrobbles
    }
}
