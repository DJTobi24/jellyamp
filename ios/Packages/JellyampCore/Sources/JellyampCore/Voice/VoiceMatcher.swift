import Foundation

/// A library item a voice query could mean. Built by the app from search
/// results; the matcher never talks to the network.
public struct VoiceCandidate: Equatable, Hashable, Sendable {
    public var kind: VoiceEntityKind
    public var id: String
    public var title: String
    /// Artist name for albums and tracks; nil otherwise.
    public var artistName: String?

    public init(kind: VoiceEntityKind, id: String, title: String, artistName: String? = nil) {
        self.kind = kind
        self.id = id
        self.title = title
        self.artistName = artistName
    }
}

public struct VoiceMatch: Equatable, Sendable {
    public var candidate: VoiceCandidate
    /// 0…1 title similarity plus small hint bonuses (so it can exceed 1).
    public var score: Double

    public init(candidate: VoiceCandidate, score: Double) {
        self.candidate = candidate
        self.score = score
    }
}

public enum VoiceResolution: Equatable, Sendable {
    /// Nothing in the library resembles the request.
    case none
    /// One clear winner — play it without asking.
    case match(VoiceMatch)
    /// Several plausible items, best first — ask the user to pick.
    case ambiguous([VoiceMatch])
}

/// Ranks library items against a spoken request and decides whether the best
/// one is safe to play without a follow-up question.
///
/// Jellyfin's `searchTerm` is a plain substring search, so the server returns
/// a noisy superset (and nothing at all for a misheard word). The app feeds
/// those results — plus cheap local lists such as playlists and genres — in
/// here to get a single, explainable ordering.
public struct VoiceMatcher: Sendable {
    /// Matches below this are dropped as unrelated.
    public var minimumScore: Double
    /// At or above this, a match counts as "what the user said".
    public var confidentScore: Double
    /// A weaker best match is still accepted when it leads the runner-up by
    /// at least this much.
    public var clearLead: Double
    /// Same-kind rivals within this distance of the best make it ambiguous.
    public var rivalWindow: Double
    /// Length of the disambiguation list.
    public var maximumChoices: Int

    public init(
        minimumScore: Double = 0.5,
        confidentScore: Double = 0.9,
        clearLead: Double = 0.15,
        rivalWindow: Double = 0.05,
        maximumChoices: Int = 5
    ) {
        self.minimumScore = minimumScore
        self.confidentScore = confidentScore
        self.clearLead = clearLead
        self.rivalWindow = rivalWindow
        self.maximumChoices = maximumChoices
    }

    // MARK: - Ranking

    /// All candidates that plausibly match, best first. Deterministic: ties
    /// fall back to kind priority, then shorter title, then title, then id.
    public func rank(query: VoiceQuery, candidates: [VoiceCandidate]) -> [VoiceMatch] {
        var seen: Set<String> = []
        var matches: [VoiceMatch] = []
        for candidate in candidates {
            // The same item can arrive from several sources (search + favorites).
            guard seen.insert("\(candidate.kind.rawValue):\(candidate.id)").inserted else { continue }
            let score = self.score(query: query, candidate: candidate)
            if score >= minimumScore {
                matches.append(VoiceMatch(candidate: candidate, score: score))
            }
        }
        return matches.sorted(by: Self.isOrderedBefore)
    }

    public func rank(spoken: String, candidates: [VoiceCandidate]) -> [VoiceMatch] {
        rank(query: VoiceQueryParser.parse(spoken), candidates: candidates)
    }

    private static func isOrderedBefore(_ lhs: VoiceMatch, _ rhs: VoiceMatch) -> Bool {
        if abs(lhs.score - rhs.score) > 1e-9 { return lhs.score > rhs.score }
        if lhs.candidate.kind != rhs.candidate.kind {
            return lhs.candidate.kind.priority < rhs.candidate.kind.priority
        }
        if lhs.candidate.title.count != rhs.candidate.title.count {
            return lhs.candidate.title.count < rhs.candidate.title.count
        }
        if lhs.candidate.title != rhs.candidate.title { return lhs.candidate.title < rhs.candidate.title }
        return lhs.candidate.id < rhs.candidate.id
    }

    // MARK: - Resolution

    public func resolve(query: VoiceQuery, candidates: [VoiceCandidate]) -> VoiceResolution {
        let ranked = rank(query: query, candidates: candidates)
        guard let best = ranked.first else { return .none }
        let choices = Array(ranked.prefix(maximumChoices))
        guard ranked.count > 1 else {
            return .match(best)
        }

        // Rivals of the *same kind* are real ambiguity ("Greatest Hits" by
        // two artists). Rivals of other kinds are settled by kind priority,
        // which `rank` already applied — nobody wants to be asked "the artist
        // Weezer or the album Weezer?".
        let sameKindRival = ranked.dropFirst().first { $0.candidate.kind == best.candidate.kind }
        if let rival = sameKindRival, best.score - rival.score < rivalWindow {
            return .ambiguous(choices)
        }
        if best.score >= confidentScore {
            return .match(best)
        }
        // A fuzzy best match is only trusted when nothing else comes close.
        if best.score - ranked[1].score >= clearLead {
            return .match(best)
        }
        return .ambiguous(choices)
    }

    public func resolve(spoken: String, candidates: [VoiceCandidate]) -> VoiceResolution {
        resolve(query: VoiceQueryParser.parse(spoken), candidates: candidates)
    }

    // MARK: - Scoring

    /// Score of one candidate: the better of the "whole text is the title"
    /// reading and the "<title> by <artist>" reading, plus the kind-hint bonus.
    public func score(query: VoiceQuery, candidate: VoiceCandidate) -> Double {
        var best = Self.titleScore(spoken: query.text, title: candidate.title)

        if let titlePart = query.titlePart, let artistPart = query.artistPart,
           let artistName = candidate.artistName {
            let titleScore = Self.titleScore(spoken: titlePart, title: candidate.title)
            let artistScore = Self.titleScore(spoken: artistPart, title: artistName)
            if titleScore >= minimumScore {
                // The named artist confirms the item or rules it out.
                let combined = artistScore >= 0.75 ? titleScore + 0.08 : titleScore - 0.3
                best = max(best, combined)
            }
        }

        guard best >= minimumScore else { return 0 }
        if let hint = query.kindHint, hint == candidate.kind {
            best += 0.05
        }
        return best
    }

    /// 0…1 similarity between spoken text and a library title.
    ///
    /// Tiers, highest first: identical → identical once edition noise or
    /// spacing is ignored → spoken text is the start of the title → every
    /// spoken word appears in the title → words match approximately
    /// (mishearings, typos). Within a tier, covering more of the title wins.
    public static func titleScore(spoken: String, title: String) -> Double {
        let spokenWords = VoiceTextNormalizer.significantWords(spoken)
        let titleWords = VoiceTextNormalizer.significantWords(title)
        guard !spokenWords.isEmpty, !titleWords.isEmpty else { return 0 }

        if spokenWords == titleWords { return 1.0 }
        if spokenWords.joined() == titleWords.joined() { return 0.98 }

        let coreWords = VoiceTextNormalizer.significantWords(VoiceTextNormalizer.strippingEditionSuffix(title))
        if spokenWords == coreWords || spokenWords.joined() == coreWords.joined() { return 0.96 }

        let spokenLength = Double(spokenWords.joined().count)
        let titleLength = Double(titleWords.joined().count)
        let coverage = min(1, spokenLength / max(1, titleLength))

        if titleWords.count > spokenWords.count, Array(titleWords.prefix(spokenWords.count)) == spokenWords {
            return 0.80 + 0.12 * coverage
        }

        let titleSet = Set(titleWords)
        if spokenWords.allSatisfy({ titleSet.contains($0) }) {
            return 0.68 + 0.12 * coverage
        }

        // Approximate: each spoken word must resemble some title word.
        let whole = wholeStringScore(spokenWords, titleWords)
        var total = 0.0
        for word in spokenWords {
            var bestWord = 0.0
            for titleWord in titleWords {
                bestWord = max(bestWord, similarity(word, titleWord))
            }
            // One unrelated word sinks the match — otherwise long titles
            // would match almost anything.
            if bestWord < 0.5 { return whole }
            total += bestWord
        }
        // Scaled so that barely-similar words on a long title fall below the
        // matcher's minimum, while a single typo lands around 0.65.
        let average = total / Double(spokenWords.count)
        let fuzzy = 0.35 + 0.35 * average * (0.5 + 0.5 * coverage)
        return max(fuzzy, whole)
    }

    /// Catches word-boundary errors ("day dream" vs "Daydream") that the
    /// per-word comparison cannot see.
    private static func wholeStringScore(_ spokenWords: [String], _ titleWords: [String]) -> Double {
        let ratio = similarity(spokenWords.joined(), titleWords.joined())
        return ratio >= 0.8 ? 0.45 + 0.4 * ratio : 0
    }

    /// Normalized Levenshtein similarity in 0…1 (1 = identical).
    public static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(lhs)
        let b = Array(rhs)
        if a.isEmpty && b.isEmpty { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        let distance = previous[b.count]
        return 1 - Double(distance) / Double(max(a.count, b.count))
    }
}
