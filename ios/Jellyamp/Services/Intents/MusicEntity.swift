import AppIntents
import Foundation
import JellyampCore

/// Anything in the library that can be played by name: an artist, album,
/// playlist, song or genre. One entity type (instead of five) lets a single
/// "Play …" phrase cover every kind, the way people actually ask.
struct MusicEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Music"
    static var defaultQuery = MusicEntityQuery()

    /// `VoiceEntityIdentifier.rawValue` — kind, Jellyfin id and name, so the
    /// system can resolve a stored entity without a server round-trip.
    var id: String
    var kind: VoiceEntityKind
    var itemID: String
    var name: String
    var artistName: String?

    init(kind: VoiceEntityKind, itemID: String, name: String, artistName: String? = nil) {
        self.id = VoiceEntityIdentifier(kind: kind, itemID: itemID, name: name).rawValue
        self.kind = kind
        self.itemID = itemID
        self.name = name
        self.artistName = artistName
    }

    init(candidate: VoiceCandidate) {
        self.init(kind: candidate.kind, itemID: candidate.id, name: candidate.title, artistName: candidate.artistName)
    }

    init?(identifier: String) {
        guard let parsed = VoiceEntityIdentifier(rawValue: identifier) else { return nil }
        self.init(kind: parsed.kind, itemID: parsed.itemID, name: parsed.name)
    }

    var ref: MusicItemRef { MusicItemRef(kind: kind, id: itemID, name: name) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(subtitleText)",
            image: DisplayRepresentation.Image(systemName: symbolName)
        )
    }

    /// "Album · Miles Davis" — the kind matters when a disambiguation list
    /// mixes an artist with their self-titled album.
    private var subtitleText: String {
        let kindName: String
        switch kind {
        case .artist: kindName = String(localized: "Artist")
        case .album: kindName = String(localized: "Album")
        case .playlist: kindName = String(localized: "Playlist")
        case .track: kindName = String(localized: "Song")
        case .genre: kindName = String(localized: "Genre")
        }
        if let artistName, !artistName.isEmpty {
            return "\(kindName) · \(artistName)"
        }
        return kindName
    }

    var symbolName: String {
        switch kind {
        case .artist: return "music.mic"
        case .album: return "square.stack"
        case .playlist: return "music.note.list"
        case .track: return "music.note"
        case .genre: return "guitars"
        }
    }
}

/// Resolves spoken or typed text to library items via `VoiceMatcher`.
struct MusicEntityQuery: EntityStringQuery {
    /// Stored identifiers carry everything needed, so this never touches the
    /// network and works signed out — Shortcuts calls it just to *display* a
    /// saved shortcut.
    func entities(for identifiers: [String]) async throws -> [MusicEntity] {
        identifiers.compactMap { MusicEntity(identifier: $0) }
    }

    /// One result when the request is unambiguous (Siri then plays without a
    /// follow-up), several — best first — when the user has to pick.
    @MainActor
    func entities(matching string: String) async throws -> [MusicEntity] {
        let commands = try await MusicCommands.live()
        let matches = await commands.voiceMatches(for: string)
        return matches.map { MusicEntity(candidate: $0) }
    }

    /// Shown in the Shortcuts picker and used by Siri to recognise names
    /// inside App Shortcut phrases. Empty while signed out.
    @MainActor
    func suggestedEntities() async throws -> [MusicEntity] {
        guard let commands = try? await MusicCommands.live() else { return [] }
        let items = await commands.suggestedItems()
        return items.map { MusicEntity(candidate: $0) }
    }
}
