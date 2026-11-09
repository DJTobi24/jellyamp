import Foundation

/// A scrobble waiting to be delivered to one service.
public struct PendingScrobble: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var service: ScrobbleServiceID
    public var listen: ScrobbleListen
    /// Deliveries the service answered with "not now".
    public var attempts: Int
    public var enqueuedAt: Date

    public init(id: UUID = UUID(), service: ScrobbleServiceID, listen: ScrobbleListen, attempts: Int = 0, enqueuedAt: Date) {
        self.id = id
        self.service = service
        self.listen = listen
        self.attempts = attempts
        self.enqueuedAt = enqueuedAt
    }
}

/// Persistence for the offline scrobble queue (a JSON file on device, memory
/// in tests). Implementations must tolerate a missing or unreadable store by
/// returning an empty queue.
public protocol ScrobbleQueueStoring: Sendable {
    func loadPendingScrobbles() -> [PendingScrobble]
    func save(pendingScrobbles: [PendingScrobble])
}

/// Limits that keep the offline queue bounded.
public struct ScrobbleQueuePolicy: Equatable, Sendable {
    /// Most entries kept across all services; the oldest are dropped first.
    public var maxEntries: Int
    /// Listens older than this are dropped. Last.fm refuses scrobbles more
    /// than two weeks old, so keeping them longer would only produce errors.
    public var maxAge: TimeInterval
    /// "Try again later" answers tolerated per listen before it is dropped.
    public var maxAttempts: Int

    public init(maxEntries: Int = 2000, maxAge: TimeInterval = 14 * 24 * 3600, maxAttempts: Int = 12) {
        self.maxEntries = maxEntries
        self.maxAge = maxAge
        self.maxAttempts = maxAttempts
    }
}

/// The offline scrobble queue as a value: all rules (dedupe, cap, expiry,
/// oldest-first batching) live here, free of I/O, and `ScrobbleEngine`
/// persists the entries after every change.
public struct ScrobbleQueue: Equatable, Sendable {
    public private(set) var entries: [PendingScrobble]
    public var policy: ScrobbleQueuePolicy

    public init(entries: [PendingScrobble] = [], policy: ScrobbleQueuePolicy = ScrobbleQueuePolicy()) {
        self.entries = entries
        self.policy = policy
    }

    public var isEmpty: Bool { entries.isEmpty }

    public func count(for service: ScrobbleServiceID) -> Int {
        entries.reduce(0) { $0 + ($1.service == service ? 1 : 0) }
    }

    /// Adds a listen for a service unless that play is already queued for it.
    /// Returns false for a duplicate.
    @discardableResult
    public mutating func enqueue(_ listen: ScrobbleListen, for service: ScrobbleServiceID, now: Date) -> Bool {
        let key = listen.playKey
        if entries.contains(where: { $0.service == service && $0.listen.playKey == key }) {
            return false
        }
        entries.append(PendingScrobble(service: service, listen: listen, enqueuedAt: now))
        enforceCap()
        return true
    }

    /// Drops listens that are too old or were retried too often. Returns
    /// how many were removed.
    @discardableResult
    public mutating func prune(now: Date) -> Int {
        let before = entries.count
        let maxAge = policy.maxAge
        let maxAttempts = policy.maxAttempts
        entries.removeAll { entry in
            now.timeIntervalSince(entry.listen.startedAt) > maxAge || entry.attempts >= maxAttempts
        }
        return before - entries.count
    }

    /// The oldest listens for a service, by start of play.
    public func nextBatch(for service: ScrobbleServiceID, limit: Int) -> [PendingScrobble] {
        let mine = entries.filter { $0.service == service }
        let sorted = mine.sorted { lhs, rhs in
            if lhs.listen.startedAt != rhs.listen.startedAt {
                return lhs.listen.startedAt < rhs.listen.startedAt
            }
            return lhs.enqueuedAt < rhs.enqueuedAt
        }
        return Array(sorted.prefix(max(0, limit)))
    }

    /// Delivered or permanently refused: either way they leave the queue.
    public mutating func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
    }

    /// The service answered "not now" for these listens.
    public mutating func recordFailedAttempt(ids: Set<UUID>) {
        for index in entries.indices where ids.contains(entries[index].id) {
            entries[index].attempts += 1
        }
    }

    /// Forget everything queued for a service (the user disconnected it).
    public mutating func removeAll(for service: ScrobbleServiceID) {
        entries.removeAll { $0.service == service }
    }

    private mutating func enforceCap() {
        let overflow = entries.count - policy.maxEntries
        guard overflow > 0 else { return }
        let oldestFirst = entries.sorted { $0.listen.startedAt < $1.listen.startedAt }
        let doomed = Set(oldestFirst.prefix(overflow).map(\.id))
        entries.removeAll { doomed.contains($0.id) }
    }
}
