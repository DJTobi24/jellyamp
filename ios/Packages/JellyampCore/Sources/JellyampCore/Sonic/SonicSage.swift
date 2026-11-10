import Foundation

/// The text of a Sonic Sage request ("rainy sunday morning jazz"), checked
/// against the limits of `POST /api/v1/sage` before it is sent so the user
/// gets an immediate, specific hint instead of a 422.
public enum SagePrompt {
    public enum ValidationError: Error, Equatable, Sendable {
        case empty
        /// The prompt exceeds `maxLength` by `excess` characters.
        case tooLong(excess: Int)
    }

    /// `SageRequest.prompt` in `server/jellyamp_server/main.py`
    /// (`min_length=1, max_length=1000`).
    public static let maxLength = 1000

    /// The form the prompt is sent and remembered in: surrounding whitespace
    /// removed and every inner run of whitespace (including the line breaks
    /// of the multi-line field) collapsed into one space.
    public static func normalize(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Length the way the server counts it: Python string lengths are
    /// Unicode code points, not grapheme clusters, so an emoji sequence that
    /// is one `Character` here may count as several there.
    public static func length(of normalized: String) -> Int {
        normalized.unicodeScalars.count
    }

    /// The normalized prompt, or why it cannot be sent.
    public static func validate(_ raw: String) -> Result<String, ValidationError> {
        let normalized = normalize(raw)
        guard !normalized.isEmpty else { return .failure(.empty) }
        let excess = length(of: normalized) - maxLength
        guard excess <= 0 else { return .failure(.tooLong(excess: excess)) }
        return .success(normalized)
    }

    /// Characters left before the limit (negative when over). The builder
    /// only shows the counter once this gets small.
    public static func remainingCharacters(for raw: String) -> Int {
        maxLength - length(of: normalize(raw))
    }
}

/// How many tracks to ask Sage for.
public enum SageTrackCount {
    /// `SageRequest.count` in `server/jellyamp_server/main.py` (`ge=1, le=200`).
    public static let allowed: ClosedRange<Int> = 1...200
    public static let choices: [Int] = [15, 30, 50]
    public static let defaultCount = 30

    public static func clamp(_ count: Int) -> Int {
        min(max(count, allowed.lowerBound), allowed.upperBound)
    }
}

/// The prompts the user sent most recently, newest first. A prompt that is
/// sent again moves to the front instead of appearing twice; comparison
/// ignores case and whitespace differences, the newest spelling wins.
public struct SageRecentPrompts: Equatable, Sendable {
    public static let defaultLimit = 10

    public private(set) var prompts: [String]
    public let limit: Int

    /// Accepts whatever was stored: entries are normalized, de-duplicated
    /// and capped again, so a hand-edited or older store cannot break the
    /// invariants.
    public init(prompts: [String] = [], limit: Int = SageRecentPrompts.defaultLimit) {
        self.limit = max(limit, 0)
        var seen = Set<String>()
        var cleaned: [String] = []
        for raw in prompts {
            let normalized = SagePrompt.normalize(raw)
            guard !normalized.isEmpty, seen.insert(Self.key(normalized)).inserted else { continue }
            cleaned.append(normalized)
        }
        self.prompts = Array(cleaned.prefix(self.limit))
    }

    public var isEmpty: Bool { prompts.isEmpty }

    /// Puts `raw` at the front. Blank prompts are ignored.
    public mutating func record(_ raw: String) {
        let normalized = SagePrompt.normalize(raw)
        guard !normalized.isEmpty else { return }
        let key = Self.key(normalized)
        prompts.removeAll { Self.key($0) == key }
        prompts.insert(normalized, at: 0)
        if prompts.count > limit {
            prompts.removeLast(prompts.count - limit)
        }
    }

    public mutating func remove(_ raw: String) {
        let key = Self.key(SagePrompt.normalize(raw))
        prompts.removeAll { Self.key($0) == key }
    }

    public mutating func removeAll() {
        prompts.removeAll()
    }

    private static func key(_ normalized: String) -> String {
        normalized.lowercased()
    }
}

/// What Sage produced, after matching the server's IDs against the library.
public struct SageResult: Equatable, Sendable {
    /// What to tell the user about the size of the result, if anything.
    public enum Notice: Equatable, Sendable {
        /// Sage matched fewer analyzed tracks than requested; all of them are
        /// in the library.
        case fewerMatches(found: Int, requested: Int)
        /// Some tracks Sage picked could not be loaded from the library
        /// (removed since the analysis, or hidden from this user).
        case missingFromLibrary(found: Int, picked: Int)
    }

    public static let fallbackTitle = "Sonic Sage"

    public let title: String
    public let description: String
    /// Resolved tracks in the server's (sonically smooth) order.
    public let tracks: [Track]
    /// Tracks asked for.
    public let requestedCount: Int
    /// Distinct track IDs the server answered with.
    public let pickedCount: Int

    /// - Parameters:
    ///   - itemIDs: the server's ordered IDs; repeats are dropped, keeping
    ///     the first occurrence.
    ///   - resolved: the library's answer for those IDs, in any order and
    ///     possibly incomplete. IDs without a track drop out; the order of
    ///     the remaining ones is preserved.
    public init(title: String, description: String, itemIDs: [String], resolved: [Track], requestedCount: Int) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = trimmedTitle.isEmpty ? Self.fallbackTitle : trimmedTitle
        self.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        let uniqueIDs = itemIDs.filter { !$0.isEmpty && seen.insert($0).inserted }
        self.tracks = SimilarRanking.ordered(resolved, byIDs: uniqueIDs)
        self.requestedCount = requestedCount
        self.pickedCount = uniqueIDs.count
    }

    /// True when none of the picked tracks could be loaded: there is nothing
    /// to play, and the screen should say so instead of showing an empty list.
    public var isEmpty: Bool { tracks.isEmpty }

    /// Missing tracks are the more surprising shortfall, so they win over
    /// "fewer matches" when both apply. nil when the result is complete (or
    /// empty — that is an error state, not a notice).
    public var notice: Notice? {
        guard !tracks.isEmpty else { return nil }
        if tracks.count < pickedCount {
            return .missingFromLibrary(found: tracks.count, picked: pickedCount)
        }
        if tracks.count < requestedCount {
            return .fewerMatches(found: tracks.count, requested: requestedCount)
        }
        return nil
    }

    public var totalDuration: TimeInterval {
        tracks.reduce(0) { $0 + $1.duration }
    }
}

/// Progress shown while Sage works. The server reports nothing until it
/// answers, so this is an estimate from elapsed time alone: it moves quickly
/// at first, slows down and never claims to be done — only the response
/// completes it.
public enum SageProgress {
    public enum Stage: Equatable, Sendable {
        /// The request is on its way.
        case sending
        /// The language model is interpreting the prompt.
        case interpreting
        /// The server is matching the criteria against the library.
        case matching
        /// Longer than usual; still within the request timeout.
        case takingLong
    }

    /// The bar never goes past this on its own.
    public static let ceiling = 0.92
    /// Seconds after which roughly 63 % of the ceiling is reached; a typical
    /// request takes 5–15 s.
    static let timeConstant = 9.0

    /// 0…`ceiling`, monotonic in `elapsed`.
    public static func estimatedFraction(elapsed: TimeInterval) -> Double {
        guard elapsed > 0 else { return 0 }
        return ceiling * (1 - exp(-elapsed / timeConstant))
    }

    public static func stage(elapsed: TimeInterval) -> Stage {
        switch elapsed {
        case ..<1.5: return .sending
        case ..<8: return .interpreting
        case ..<20: return .matching
        default: return .takingLong
        }
    }
}
