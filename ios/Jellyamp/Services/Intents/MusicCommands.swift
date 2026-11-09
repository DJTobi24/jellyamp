import Foundation
import JellyampCore
import JellyfinBackend
import SonicClient

/// Why a voice / CarPlay command could not run. The text is what Siri speaks
/// and what the CarPlay alert shows, so it is written for a listener.
enum MusicCommandError: Error, Equatable, CustomLocalizedStringResourceConvertible, LocalizedError {
    case notSignedIn
    case nothingPlaying
    case notFound(String)
    case noPlayableTracks(String)
    case nothingLiked
    case nothingRecentlyAdded
    case nothingDownloaded

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn:
            return "You're not signed in. Open Jellyamp and connect to your Jellyfin server first."
        case .nothingPlaying:
            return "Nothing is playing right now."
        case .notFound(let name):
            return "Couldn't find \(name) in your library."
        case .noPlayableTracks(let name):
            return "\(name) doesn't have any songs to play."
        case .nothingLiked:
            return "You don't have any liked songs yet."
        case .nothingRecentlyAdded:
            return "Nothing has been added to your library recently."
        case .nothingDownloaded:
            return "You don't have any downloads yet."
        }
    }

    var errorDescription: String? { String(localized: localizedStringResource) }
}

/// A library item named by kind — the common currency of intents and CarPlay.
struct MusicItemRef: Equatable, Sendable {
    var kind: VoiceEntityKind
    var id: String
    var name: String
}

/// What a command started, for the spoken confirmation.
struct PlaybackSummary: Equatable, Sendable {
    var title: String
    var subtitle: String?
    var trackCount: Int
}

/// The playback actions shared by Siri / Shortcuts intents and CarPlay.
///
/// Both run outside the SwiftUI view tree, possibly in a process that was
/// just launched in the background, so `live()` first makes sure the stored
/// session has been restored and fails with a speakable error otherwise.
@MainActor
struct MusicCommands {
    let container: DependencyContainer
    let library: MusicLibraryProviding
    let player: PlayerEngine

    /// The commands for the running app, restoring the session if needed.
    static func live() async throws -> MusicCommands {
        let container = DependencyContainer.shared
        await container.waitUntilPlayable()
        guard container.isSignedIn, let library = container.library, let player = container.player else {
            throw MusicCommandError.notSignedIn
        }
        return MusicCommands(container: container, library: library, player: player)
    }

    // MARK: - Playing library items

    func tracks(for item: MusicItemRef) async throws -> [Track] {
        switch item.kind {
        case .artist:
            return try await library.tracks(byArtist: item.id)
        case .album:
            return try await library.tracks(inAlbum: item.id)
        case .playlist:
            return try await library.tracks(inPlaylist: item.id)
        case .track:
            return try await library.tracks(byIDs: [item.id])
        case .genre:
            return try await library.tracks(inGenre: item.id)
        }
    }

    @discardableResult
    func play(_ item: MusicItemRef, shuffled: Bool) async throws -> PlaybackSummary {
        let tracks = try await self.tracks(for: item)
        guard let first = tracks.first else {
            throw MusicCommandError.noPlayableTracks(item.name)
        }
        // "Play <artist>" or "play <genre>" means a mix of their music, not
        // their catalogue in alphabetical album order.
        let shuffle = shuffled || item.kind == .artist || item.kind == .genre
        if shuffle && tracks.count > 1 {
            player.playShuffled(tracks)
        } else {
            player.load(queue: PlayQueue(tracks: tracks))
        }
        let subtitle: String?
        switch item.kind {
        case .album, .track:
            subtitle = first.artistName.isEmpty ? nil : first.artistName
        case .artist, .playlist, .genre:
            subtitle = nil
        }
        return PlaybackSummary(title: item.name, subtitle: subtitle, trackCount: tracks.count)
    }

    @discardableResult
    func shuffleLikedSongs() async throws -> PlaybackSummary {
        let tracks = try await library.favoriteTracks(limit: 500)
        guard !tracks.isEmpty else { throw MusicCommandError.nothingLiked }
        player.playShuffled(tracks)
        return PlaybackSummary(title: String(localized: "Liked Songs"), subtitle: nil, trackCount: tracks.count)
    }

    /// Queues the newest albums back to back, newest first.
    @discardableResult
    func playRecentlyAdded(albumLimit: Int = 5) async throws -> PlaybackSummary {
        let albums = try await library.recentlyAddedAlbums(limit: albumLimit)
        var tracks: [Track] = []
        for album in albums {
            // One unreadable album must not fail the whole request.
            if let albumTracks = try? await library.tracks(inAlbum: album.id) {
                tracks.append(contentsOf: albumTracks)
            }
        }
        guard !tracks.isEmpty, let newest = albums.first else { throw MusicCommandError.nothingRecentlyAdded }
        player.load(queue: PlayQueue(tracks: tracks))
        return PlaybackSummary(title: newest.title, subtitle: newest.artistName, trackCount: tracks.count)
    }

    @discardableResult
    func shuffleDownloads() throws -> PlaybackSummary {
        let tracks = container.downloads?.downloaded ?? []
        guard !tracks.isEmpty else { throw MusicCommandError.nothingDownloaded }
        player.playShuffled(tracks)
        return PlaybackSummary(title: String(localized: "Downloads"), subtitle: nil, trackCount: tracks.count)
    }

    // MARK: - Radio

    /// Starts an endless station from any item. With jellyamp-server this is
    /// sonic similarity; against plain Jellyfin it is Instant Mix / a random
    /// genre selection. The container's autoplay keeps it going afterwards.
    @discardableResult
    func startRadio(from item: MusicItemRef, count: Int = 50) async throws -> PlaybackSummary {
        // The sonic provider is wired at the very end of bootstrap.
        await container.ensureBootstrapped()

        var queue: [Track] = []
        if item.kind == .genre {
            queue = await genreStation(named: item.name, count: count)
            if queue.isEmpty {
                let genreTracks = try await library.tracks(inGenre: item.id)
                queue = Array(genreTracks.shuffled().prefix(count))
            }
        } else {
            let seed = try await radioSeed(for: item)
            let similar = await similarTracks(to: seed, count: count)
            queue = [seed] + similar
            if similar.isEmpty, item.kind != .track {
                // No similarity data at all: at least keep playing the item.
                let all = try await self.tracks(for: item)
                let rest = all.filter { $0.id != seed.id }.shuffled()
                queue.append(contentsOf: rest.prefix(count))
            }
        }
        guard !queue.isEmpty else { throw MusicCommandError.noPlayableTracks(item.name) }
        player.load(queue: PlayQueue(tracks: queue))
        return PlaybackSummary(title: item.name, subtitle: nil, trackCount: queue.count)
    }

    private func radioSeed(for item: MusicItemRef) async throws -> Track {
        var candidates: [Track] = []
        if item.kind == .artist {
            // An artist's most played song is the most representative seed.
            candidates = (try? await library.topTracks(byArtist: item.id, limit: 1)) ?? []
        }
        if candidates.isEmpty {
            candidates = try await self.tracks(for: item)
        }
        let seed = item.kind == .artist || item.kind == .track ? candidates.first : candidates.randomElement()
        guard let seed else { throw MusicCommandError.noPlayableTracks(item.name) }
        return seed
    }

    private func similarTracks(to seed: Track, count: Int) async -> [Track] {
        guard let sonic = container.sonic,
              let similar = try? await sonic.similarTracks(to: seed.id, limit: count),
              !similar.isEmpty else { return [] }
        let tracks = (try? await library.tracks(byIDs: similar.map(\.itemID))) ?? []
        return tracks.filter { $0.id != seed.id }
    }

    private func genreStation(named name: String, count: Int) async -> [Track] {
        guard container.sonicCapabilities.supports(.stations), let sonic = container.sonic,
              let ids = try? await sonic.station(type: .genre, seed: name, count: count),
              !ids.isEmpty else { return [] }
        return (try? await library.tracks(byIDs: ids)) ?? []
    }

    // MARK: - Transport

    var currentTrack: Track? { container.playerState.currentTrack }

    func resume() throws {
        guard currentTrack != nil else { throw MusicCommandError.nothingPlaying }
        player.play()
    }

    func pause() {
        player.pause()
    }

    /// Returns true when playback is running after the toggle.
    func togglePlayback() throws -> Bool {
        guard currentTrack != nil else { throw MusicCommandError.nothingPlaying }
        if container.playerState.isPlaying {
            player.pause()
            return false
        }
        player.play()
        return true
    }

    func skipToNext() throws {
        guard currentTrack != nil else { throw MusicCommandError.nothingPlaying }
        player.skipToNext()
    }

    func skipToPrevious() throws {
        guard currentTrack != nil else { throw MusicCommandError.nothingPlaying }
        player.skipToPrevious()
    }

    /// Likes (or unlikes) the playing song on the server and mirrors the new
    /// state into the player model so every surface shows the same heart.
    @discardableResult
    func setCurrentTrackFavorite(_ isFavorite: Bool) async throws -> Track {
        guard let track = currentTrack else { throw MusicCommandError.nothingPlaying }
        try await library.setFavorite(itemID: track.id, isFavorite: isFavorite)
        // Only if the same song is still playing — the request takes a moment.
        if container.playerState.currentTrack?.id == track.id {
            container.playerState.currentTrack?.isFavorite = isFavorite
        }
        var updated = track
        updated.isFavorite = isFavorite
        return updated
    }

    /// `duration` nil means "until the end of the current track".
    func startSleepTimer(duration: TimeInterval?) throws {
        guard currentTrack != nil else { throw MusicCommandError.nothingPlaying }
        player.startSleepTimer(duration: duration)
    }

    func cancelSleepTimer() {
        player.cancelSleepTimer()
    }

    // MARK: - Voice search

    /// Library items that could be meant by `spoken`, already resolved: a
    /// single element when one item clearly wins, several (best first) when
    /// the user should choose, empty when nothing fits.
    func voiceMatches(for spoken: String) async -> [VoiceCandidate] {
        let query = VoiceQueryParser.parse(spoken)
        guard !query.text.isEmpty else { return [] }

        var candidates: [VoiceCandidate] = []
        if let result = try? await library.search(query: query.text, limit: 25) {
            candidates += Self.candidates(tracks: result.tracks, albums: result.albums, artists: result.artists, playlists: result.playlists)
        }
        // "Hurt by Johnny Cash" finds nothing as one search term; the title
        // alone does, and the matcher checks the artist.
        if let titlePart = query.titlePart, let result = try? await library.search(query: titlePart, limit: 25) {
            candidates += Self.candidates(tracks: result.tracks, albums: result.albums, artists: result.artists, playlists: result.playlists)
        }

        // Server search is a substring match, so a misheard or re-spelled
        // name returns nothing. These local lists give the fuzzy matcher
        // something to work with (and playlists/genres are short anyway).
        if let playlists = try? await library.playlists() {
            candidates += playlists.map { VoiceCandidate(kind: .playlist, id: $0.id, title: $0.name) }
        }
        if let genres = try? await library.genres() {
            candidates += genres.map { VoiceCandidate(kind: .genre, id: $0.id, title: $0.name) }
        }
        if let cache = container.libraryCache {
            let artists = cache.load([Artist].self, for: LibraryCacheKey.allArtists) ?? []
            candidates += artists.map { VoiceCandidate(kind: .artist, id: $0.id, title: $0.name) }
            let albums = cache.load([Album].self, for: LibraryCacheKey.allAlbums) ?? []
            candidates += albums.map {
                VoiceCandidate(kind: .album, id: $0.id, title: $0.title, artistName: $0.artistName)
            }
        }

        switch VoiceMatcher().resolve(query: query, candidates: candidates) {
        case .none:
            return []
        case .match(let match):
            return [match.candidate]
        case .ambiguous(let matches):
            return matches.map(\.candidate)
        }
    }

    private static func candidates(tracks: [Track], albums: [Album], artists: [Artist], playlists: [Playlist]) -> [VoiceCandidate] {
        var result: [VoiceCandidate] = []
        result += artists.map { VoiceCandidate(kind: .artist, id: $0.id, title: $0.name) }
        result += albums.map { VoiceCandidate(kind: .album, id: $0.id, title: $0.title, artistName: $0.artistName) }
        result += playlists.map { VoiceCandidate(kind: .playlist, id: $0.id, title: $0.name) }
        result += tracks.map { VoiceCandidate(kind: .track, id: $0.id, title: $0.title, artistName: $0.artistName) }
        return result
    }

    /// Items worth offering before the user says anything: their playlists,
    /// favorites, newest albums and genres. Siri can only recognise a name
    /// inside an App Shortcut phrase ("Play Road Trip in Jellyamp") when the
    /// item is in this list, so it is generous but bounded.
    func suggestedItems(limit: Int = 200) async -> [VoiceCandidate] {
        var items: [VoiceCandidate] = []
        if let playlists = try? await library.playlists() {
            items += playlists.map { VoiceCandidate(kind: .playlist, id: $0.id, title: $0.name) }
        }
        if let artists = try? await library.favoriteArtists(limit: 50) {
            items += artists.map { VoiceCandidate(kind: .artist, id: $0.id, title: $0.name) }
        }
        if let albums = try? await library.favoriteAlbums(limit: 50) {
            items += albums.map { VoiceCandidate(kind: .album, id: $0.id, title: $0.title, artistName: $0.artistName) }
        }
        if let albums = try? await library.recentlyAddedAlbums(limit: 20) {
            items += albums.map { VoiceCandidate(kind: .album, id: $0.id, title: $0.title, artistName: $0.artistName) }
        }
        if let genres = try? await library.genres() {
            items += genres.map { VoiceCandidate(kind: .genre, id: $0.id, title: $0.name) }
        }
        if let cache = container.libraryCache {
            let artists = cache.load([Artist].self, for: LibraryCacheKey.allArtists) ?? []
            items += artists.map { VoiceCandidate(kind: .artist, id: $0.id, title: $0.name) }
        }
        var seen: Set<String> = []
        let unique = items.filter { !$0.title.isEmpty && seen.insert("\($0.kind.rawValue):\($0.id)").inserted }
        return Array(unique.prefix(limit))
    }
}

extension DependencyContainer {
    /// Returns as soon as the stored session (if any) is usable for playback,
    /// without waiting for the rest of bootstrap.
    ///
    /// Bootstrap ends with a network probe of the optional sonic server; an
    /// intent that only wants to press "play" must not sit through that, or
    /// Siri gives up with "that's taking too long". Library and player are
    /// created before the probe, so their presence is the signal.
    func waitUntilPlayable() async {
        Task { await self.ensureBootstrapped() }
        while !isBootstrapped && player == nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
