import Foundation

/// What kind of library item a voice request can resolve to.
public enum VoiceEntityKind: String, Codable, CaseIterable, Sendable {
    case artist
    case album
    case playlist
    case track
    case genre

    /// Tie-break order when different kinds match a query equally well.
    ///
    /// "Play Weezer" should start the artist, not ask about the self-titled
    /// album; a playlist the user named themselves beats a genre or album
    /// that happens to share the word; albums beat their title tracks.
    public var priority: Int {
        switch self {
        case .artist: return 0
        case .playlist: return 1
        case .genre: return 2
        case .album: return 3
        case .track: return 4
        }
    }
}

/// A spoken request after the command words are peeled off.
public struct VoiceQuery: Equatable, Sendable {
    /// The full request minus filler ("play", "some", "the album").
    public var text: String
    /// Set when the user named the kind ("the album …", "songs by …").
    public var kindHint: VoiceEntityKind?
    /// `text` split at its last " by ": "Hurt by Johnny Cash" → title "Hurt",
    /// artist "Johnny Cash". Only a *candidate* reading — "Stand by Me" also
    /// splits — so the matcher scores both readings and keeps the better one.
    public var titlePart: String?
    public var artistPart: String?

    public init(text: String, kindHint: VoiceEntityKind? = nil, titlePart: String? = nil, artistPart: String? = nil) {
        self.text = text
        self.kindHint = kindHint
        self.titlePart = titlePart
        self.artistPart = artistPart
    }
}

/// Peels command and filler words off a dictated request.
///
/// Siri usually hands an App Intent only the parameter text, but Shortcuts
/// "Ask Each Time", typed Spotlight input and "play the album X" phrasing all
/// deliver more than the bare title, so the parser is deliberately forgiving.
public enum VoiceQueryParser {
    private static let commandPrefixes: [[String]] = [
        ["play"], ["listen", "to"], ["put", "on"], ["start"], ["shuffle"], ["queue"], ["hear"],
    ]

    /// Longest first, so "the album" wins over "the".
    private static let kindPrefixes: [([String], VoiceEntityKind)] = [
        (["the", "album"], .album), (["album"], .album), (["the", "record"], .album),
        (["the", "song"], .track), (["song"], .track), (["the", "track"], .track), (["track"], .track),
        (["the", "playlist"], .playlist), (["my", "playlist"], .playlist), (["playlist"], .playlist),
        (["the", "artist"], .artist), (["artist"], .artist), (["the", "band"], .artist),
        (["music", "by"], .artist), (["songs", "by"], .artist), (["something", "by"], .artist),
        (["anything", "by"], .artist), (["tracks", "by"], .artist),
        (["the", "genre"], .genre), (["genre"], .genre),
    ]

    private static let fillerPrefixes: [[String]] = [["some"], ["my"], ["me"]]

    /// Trailing words nobody means literally: "jazz music", "my chill
    /// playlist", "Beatles songs". Some imply a kind, the rest are just noise.
    private static let kindSuffixes: [([String], VoiceEntityKind?)] = [
        (["music"], .genre), (["playlist"], .playlist), (["album"], .album),
        (["songs"], nil), (["radio"], nil), (["station"], nil),
    ]

    public static func parse(_ raw: String) -> VoiceQuery {
        // Work on the original words so the result keeps its casing and
        // diacritics; compare on their normalized forms.
        var tokens = raw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        var kindHint: VoiceEntityKind?

        func normalized(_ token: String) -> String { VoiceTextNormalizer.words(token).joined() }

        func dropPrefix(_ prefix: [String]) -> Bool {
            // Never consume the whole request: a band called "Start" or an
            // album called "Album" must stay searchable.
            guard tokens.count > prefix.count else { return false }
            for (offset, word) in prefix.enumerated() where normalized(tokens[offset]) != word {
                return false
            }
            tokens.removeFirst(prefix.count)
            return true
        }

        func dropSuffix(_ suffix: [String]) -> Bool {
            guard tokens.count > suffix.count else { return false }
            let tail = tokens.suffix(suffix.count).map(normalized)
            guard tail == suffix else { return false }
            tokens.removeLast(suffix.count)
            return true
        }

        for prefix in commandPrefixes where dropPrefix(prefix) { break }
        for prefix in fillerPrefixes where dropPrefix(prefix) { break }
        for (prefix, kind) in kindPrefixes where dropPrefix(prefix) {
            kindHint = kind
            break
        }
        if kindHint == nil {
            for (suffix, kind) in kindSuffixes where dropSuffix(suffix) {
                kindHint = kind
                break
            }
        }

        let text = tokens.joined(separator: " ")
        var query = VoiceQuery(text: text, kindHint: kindHint)

        // Last " by " with words on both sides → possible "<title> by <artist>".
        if kindHint != .artist,
           let byIndex = tokens.lastIndex(where: { normalized($0) == "by" }),
           byIndex > 0, byIndex < tokens.count - 1 {
            query.titlePart = tokens[..<byIndex].joined(separator: " ")
            query.artistPart = tokens[(byIndex + 1)...].joined(separator: " ")
        }
        return query
    }
}
