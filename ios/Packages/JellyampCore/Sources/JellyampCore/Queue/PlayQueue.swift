import Foundation

/// Repeat behaviour of the queue.
public enum RepeatMode: String, Codable, CaseIterable, Sendable {
    case off
    case all
    case one
}

/// The ordered play queue: upcoming items, history, shuffle and repeat.
///
/// Pure value-semantics state machine — the audio engine observes it, the UI
/// mutates it. Shuffle keeps the original ordering so it can be restored.
public struct PlayQueue: Equatable, Sendable {
    public private(set) var tracks: [Track]
    public private(set) var currentIndex: Int?
    public private(set) var repeatMode: RepeatMode
    public private(set) var isShuffled: Bool

    /// Original order while shuffled, so un-shuffling restores it.
    private var unshuffledTracks: [Track]?

    public init(tracks: [Track] = [], startAt index: Int? = nil, repeatMode: RepeatMode = .off) {
        self.tracks = tracks
        self.currentIndex = tracks.isEmpty ? nil : min(max(index ?? 0, 0), tracks.count - 1)
        self.repeatMode = repeatMode
        self.isShuffled = false
        self.unshuffledTracks = nil
    }

    public var currentTrack: Track? {
        guard let index = currentIndex, tracks.indices.contains(index) else { return nil }
        return tracks[index]
    }

    public var upNext: [Track] {
        guard let index = currentIndex else { return tracks }
        return Array(tracks.dropFirst(index + 1))
    }

    public var remainingCount: Int { upNext.count }

    /// The track that will play after the current one, honoring repeat mode.
    public var nextTrack: Track? {
        guard let index = nextIndex() else { return nil }
        return tracks[index]
    }

    private func nextIndex() -> Int? {
        guard let index = currentIndex, !tracks.isEmpty else { return nil }
        switch repeatMode {
        case .one:
            return index
        case .all:
            return (index + 1) % tracks.count
        case .off:
            let next = index + 1
            return tracks.indices.contains(next) ? next : nil
        }
    }

    /// Advance to the next track. Returns the new current track, or nil when
    /// the queue is exhausted.
    @discardableResult
    public mutating func advance() -> Track? {
        guard let next = nextIndex() else {
            currentIndex = nil
            return nil
        }
        currentIndex = next
        return currentTrack
    }

    /// Explicit user "skip next": repeat-one does not pin skips.
    @discardableResult
    public mutating func skipToNext() -> Track? {
        guard let index = currentIndex, !tracks.isEmpty else { return nil }
        let next = index + 1
        if tracks.indices.contains(next) {
            currentIndex = next
        } else if repeatMode != .off {
            currentIndex = 0
        } else {
            return nil
        }
        return currentTrack
    }

    @discardableResult
    public mutating func skipToPrevious() -> Track? {
        guard let index = currentIndex, !tracks.isEmpty else { return nil }
        if index > 0 {
            currentIndex = index - 1
        } else if repeatMode != .off {
            currentIndex = tracks.count - 1
        }
        return currentTrack
    }

    public mutating func jump(to index: Int) {
        guard tracks.indices.contains(index) else { return }
        currentIndex = index
    }

    public mutating func setRepeatMode(_ mode: RepeatMode) {
        repeatMode = mode
    }

    // MARK: - Mutations

    /// Insert tracks immediately after the current one ("Play Next").
    public mutating func insertNext(_ newTracks: [Track]) {
        guard !newTracks.isEmpty else { return }
        let insertAt = (currentIndex ?? -1) + 1
        tracks.insert(contentsOf: newTracks, at: min(insertAt, tracks.count))
        if currentIndex == nil { currentIndex = 0 }
        unshuffledTracks?.append(contentsOf: newTracks)
    }

    /// Append tracks to the end of the queue ("Add to Queue").
    public mutating func append(_ newTracks: [Track]) {
        guard !newTracks.isEmpty else { return }
        tracks.append(contentsOf: newTracks)
        if currentIndex == nil { currentIndex = 0 }
        unshuffledTracks?.append(contentsOf: newTracks)
    }

    public mutating func remove(at index: Int) {
        guard tracks.indices.contains(index), index != currentIndex else { return }
        let removed = tracks.remove(at: index)
        if let current = currentIndex, index < current {
            currentIndex = current - 1
        }
        unshuffledTracks?.removeAll { $0 == removed }
    }

    public mutating func move(from source: Int, to destination: Int) {
        guard tracks.indices.contains(source), tracks.indices.contains(destination), source != destination else { return }
        let track = tracks.remove(at: source)
        tracks.insert(track, at: destination)
        if let current = currentIndex {
            if source == current {
                currentIndex = destination
            } else if source < current && destination >= current {
                currentIndex = current - 1
            } else if source > current && destination <= current {
                currentIndex = current + 1
            }
        }
    }

    // MARK: - Shuffle

    /// Shuffle upcoming tracks; the current track stays in place. A seed makes
    /// the order reproducible (and testable).
    public mutating func shuffle(seed: UInt64 = .random(in: .min ... .max)) {
        guard !isShuffled, tracks.count > 1 else { return }
        unshuffledTracks = tracks
        var generator = SplitMix64(seed: seed)
        if let index = currentIndex {
            let current = tracks[index]
            var rest = tracks
            rest.remove(at: index)
            rest.shuffle(using: &generator)
            tracks = [current] + rest
            currentIndex = 0
        } else {
            tracks.shuffle(using: &generator)
        }
        isShuffled = true
    }

    /// Restore the original order, keeping the current track current.
    public mutating func unshuffle() {
        guard isShuffled, let original = unshuffledTracks else { return }
        let current = currentTrack
        tracks = original
        currentIndex = current.flatMap { tracks.firstIndex(of: $0) } ?? (tracks.isEmpty ? nil : 0)
        unshuffledTracks = nil
        isShuffled = false
    }
}

/// Small deterministic RNG so shuffles are reproducible in tests.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
