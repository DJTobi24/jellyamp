import Foundation

/// Exponential backoff for transient download failures.
public struct DownloadRetryPolicy: Equatable, Sendable {
    /// Attempts per track before giving up (a manual retry starts over).
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int = 5, baseDelay: TimeInterval = 5, maxDelay: TimeInterval = 600) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// Delay before the next try after `attempt` failed attempts: 5 s, 10 s,
    /// 20 s, … capped at `maxDelay`.
    public func delay(afterAttempt attempt: Int) -> TimeInterval {
        let exponent = Double(max(attempt, 1) - 1)
        return min(baseDelay * pow(2, exponent), maxDelay)
    }

    public enum Decision: Equatable, Sendable {
        case retry(after: TimeInterval)
        case giveUp
    }

    public func decision(for failure: DownloadFailure, attempt: Int) -> Decision {
        guard failure.isTransient, attempt < maxAttempts else { return .giveUp }
        return .retry(after: delay(afterAttempt: attempt))
    }
}

public struct DownloadQueuePolicy: Equatable, Sendable {
    /// Transfers running at once. Small on purpose: originals are large and a
    /// home server's uplink is usually the bottleneck.
    public var maxConcurrent: Int
    public var retry: DownloadRetryPolicy

    public init(maxConcurrent: Int = 3, retry: DownloadRetryPolicy = DownloadRetryPolicy()) {
        self.maxConcurrent = maxConcurrent
        self.retry = retry
    }
}

/// The download queue's state machine, expressed as transitions on the index.
/// The app shell reports what URLSession did; these decide what happens next.
extension DownloadIndex {
    /// Picks what to start now — oldest queued entries and due retries, up to
    /// the concurrency limit — and marks them `downloading`.
    public mutating func startNext(now: Date, policy: DownloadQueuePolicy = DownloadQueuePolicy()) -> [DownloadEntry] {
        let running = entries.values.filter { $0.phase == .downloading }.count
        var slots = policy.maxConcurrent - running
        guard slots > 0 else { return [] }
        var started: [DownloadEntry] = []
        for candidate in orderedEntries {
            guard slots > 0 else { break }
            let isDue: Bool
            switch candidate.phase {
            case .queued:
                isDue = true
            case .waitingToRetry:
                isDue = (candidate.retryAt ?? now) <= now
            case .downloading, .paused, .failed, .complete:
                isDue = false
            }
            guard isDue else { continue }
            var entry = candidate
            entry.phase = .downloading
            entry.attempts += 1
            entry.retryAt = nil
            entries[entry.id] = entry
            started.append(entry)
            slots -= 1
        }
        return started
    }

    /// When the next automatic retry becomes due, if any.
    public var nextRetryDate: Date? {
        entries.values.filter { $0.phase == .waitingToRetry }.compactMap(\.retryAt).min()
    }

    public mutating func markCompleted(id: String, bytes: Int64, now: Date) {
        guard var entry = entries[id] else { return }
        entry.phase = .complete
        entry.bytes = bytes
        entry.failure = nil
        entry.retryAt = nil
        entry.completedAt = now
        entries[id] = entry
    }

    /// Records a failed attempt and schedules a retry or gives up.
    @discardableResult
    public mutating func markFailed(
        id: String,
        failure: DownloadFailure,
        now: Date,
        policy: DownloadRetryPolicy = DownloadRetryPolicy()
    ) -> DownloadRetryPolicy.Decision {
        guard var entry = entries[id], entry.phase != .complete else { return .giveUp }
        // A transfer the user paused may still report its cancellation.
        guard entry.phase != .paused else { return .giveUp }
        let decision = policy.decision(for: failure, attempt: entry.attempts)
        entry.failure = failure
        switch decision {
        case .retry(let delay):
            entry.phase = .waitingToRetry
            entry.retryAt = now.addingTimeInterval(delay)
        case .giveUp:
            entry.phase = .failed
            entry.retryAt = nil
        }
        entries[id] = entry
        return decision
    }

    /// Pauses one download. Returns true if a running transfer must be stopped.
    @discardableResult
    public mutating func pause(id: String) -> Bool {
        guard var entry = entries[id] else { return false }
        switch entry.phase {
        case .queued, .downloading, .waitingToRetry:
            let wasRunning = entry.phase == .downloading
            entry.phase = .paused
            entry.retryAt = nil
            entries[id] = entry
            return wasRunning
        case .paused, .failed, .complete:
            return false
        }
    }

    public mutating func resume(id: String) {
        guard var entry = entries[id], entry.phase == .paused else { return }
        entry.phase = .queued
        entries[id] = entry
    }

    /// Manual retry: back to the queue with a fresh attempt budget.
    public mutating func retry(id: String) {
        guard var entry = entries[id], entry.phase == .failed || entry.phase == .waitingToRetry else { return }
        entry.phase = .queued
        entry.attempts = 0
        entry.failure = nil
        entry.retryAt = nil
        entries[id] = entry
    }

    /// A transfer was stopped for reasons that are not the track's fault
    /// (settings changed, task lost): queue it again without using an attempt.
    public mutating func requeue(id: String) {
        guard var entry = entries[id], entry.phase == .downloading else { return }
        entry.phase = .queued
        entry.attempts = max(entry.attempts - 1, 0)
        entries[id] = entry
    }

    /// Pauses everything unfinished; returns the ids whose transfers must stop.
    public mutating func pauseAll() -> [String] {
        var running: [String] = []
        for entry in pendingEntries where entry.phase != .failed {
            if pause(id: entry.id) { running.append(entry.id) }
        }
        return running
    }

    public mutating func resumeAll() {
        for entry in pendingEntries { resume(id: entry.id) }
    }

    public mutating func retryAllFailed() {
        for entry in pendingEntries where entry.phase == .failed { retry(id: entry.id) }
    }

    public struct Reconciliation: Equatable, Sendable {
        /// Files in the downloads directory no entry owns; delete them.
        public var orphanFiles: [String] = []
        /// Live transfers no entry wants any more; cancel them.
        public var strayTaskIDs: [String] = []
        /// Whether the index changed and must be saved.
        public var changed = false
    }

    /// Brings the index back in line with reality after a launch: background
    /// transfers may have finished (their file is in place) or died while the
    /// app was not running, and files may have been deleted behind our back.
    ///
    /// - Parameters:
    ///   - liveTaskIDs: track ids URLSession still has a transfer for
    ///   - files: audio files present in the downloads directory, with sizes
    public mutating func reconcile(liveTaskIDs: Set<String>, files: [String: Int64], now: Date) -> Reconciliation {
        var result = Reconciliation()
        var ownedFiles = Set<String>()
        for original in orderedEntries {
            var entry = original
            let isLive = liveTaskIDs.contains(entry.id)
            // Older versions wrote `<id>.<container>`; adopt whichever exists.
            let legacyName = DownloadFileNaming.legacyFileName(for: entry.track)
            if files[entry.fileName] == nil, files[legacyName] != nil {
                entry.fileName = legacyName
            }
            let fileSize = files[entry.fileName]
            ownedFiles.insert(entry.fileName)

            if let fileSize, !isLive {
                // The file only ever appears at its final path once complete.
                if entry.phase != .complete || entry.bytes != fileSize {
                    entry.phase = .complete
                    entry.bytes = fileSize
                    entry.failure = nil
                    entry.retryAt = nil
                    entry.completedAt = entry.completedAt ?? now
                }
            } else if fileSize == nil {
                switch entry.phase {
                case .complete:
                    // File vanished: fetch it again.
                    entry.phase = isLive ? .downloading : .queued
                    entry.attempts = 0
                    entry.bytes = 0
                    entry.completedAt = nil
                case .downloading:
                    if !isLive {
                        entry.phase = .queued
                        entry.attempts = max(entry.attempts - 1, 0)
                    }
                case .queued, .waitingToRetry:
                    if isLive { entry.phase = .downloading }
                case .paused, .failed:
                    if isLive { result.strayTaskIDs.append(entry.id) }
                }
            }
            if entry != original {
                entries[entry.id] = entry
                result.changed = true
            }
        }
        result.strayTaskIDs.append(contentsOf: liveTaskIDs.filter { entries[$0] == nil }.sorted())
        result.orphanFiles = files.keys.filter { !ownedFiles.contains($0) }.sorted()
        return result
    }
}
