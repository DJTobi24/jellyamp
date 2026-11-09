import Foundation
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Supplies the current downloaded library (the app shell's download manager).
public protocol OfflineCatalogProviding: Sendable {
    func offlineCatalog() async -> OfflineCatalog
}

/// Thrown for actions that change server state while the server can't be
/// reached. There is deliberately no offline operation queue: the UI shows
/// this message and the user repeats the action when back online.
public enum OfflineLibraryError: Error, Equatable, LocalizedError {
    public enum Action: String, Equatable, Sendable {
        case changeFavorite
        case editPlaylist
    }

    case unavailableOffline(Action)

    public var errorDescription: String? {
        switch self {
        case .unavailableOffline(.changeFavorite):
            return "You're offline. Favorites can be changed again once your server is reachable."
        case .unavailableOffline(.editPlaylist):
            return "You're offline. Playlists can be edited again once your server is reachable."
        }
    }
}

/// Decorator around the online library that serves the downloaded catalog
/// when offline mode is on or the server can't be reached, so every screen
/// keeps working from what is on the device.
///
/// A request that fails for connectivity reasons marks the server unreachable
/// (see `OfflineStateTracker`) and is answered from downloads; HTTP errors
/// from a reachable server are passed through untouched.
public final class OfflineLibrary: MusicLibraryProviding, @unchecked Sendable {
    private let online: MusicLibraryProviding
    private let catalog: OfflineCatalogProviding
    private let state: OfflineStateTracker
    private let isConnectivityError: @Sendable (Error) -> Bool
    private let onGenresFetched: (@Sendable ([Genre]) -> Void)?

    /// - Parameters:
    ///   - isConnectivityError: classifies thrown errors; injectable for tests
    ///   - onGenresFetched: receives the server's genre list so the caller can
    ///     remember id → name for offline genre lookups
    public init(
        online: MusicLibraryProviding,
        catalog: OfflineCatalogProviding,
        state: OfflineStateTracker,
        isConnectivityError: @escaping @Sendable (Error) -> Bool = OfflineLibrary.isConnectivityError(_:),
        onGenresFetched: (@Sendable ([Genre]) -> Void)? = nil
    ) {
        self.online = online
        self.catalog = catalog
        self.state = state
        self.isConnectivityError = isConnectivityError
        self.onGenresFetched = onGenresFetched
    }

    /// True for "could not talk to the server at all" errors.
    @Sendable
    public static func isConnectivityError(_ error: Error) -> Bool {
        if error is HTTPTransportError { return true }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        let codes: Set<URLError.Code> = [
            .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
            .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed,
            .resourceUnavailable, .callIsActive,
        ]
        // Compared by raw value: `URLError.Code(rawValue:)` is failable on
        // Linux but not on Apple platforms.
        return codes.contains { $0.rawValue == nsError.code }
    }

    // MARK: Routing

    private func read<T>(
        online request: () async throws -> T,
        offline fallback: (OfflineCatalog) -> T
    ) async throws -> T {
        switch state.route() {
        case .offline:
            return fallback(await catalog.offlineCatalog())
        case .online, .probe:
            do {
                let value = try await request()
                state.recordRequestSuccess()
                return value
            } catch {
                guard isConnectivityError(error) else {
                    // The server answered (with an error): it is reachable.
                    if error is JellyfinError { state.recordRequestSuccess() }
                    throw error
                }
                state.recordConnectivityFailure()
                return fallback(await catalog.offlineCatalog())
            }
        }
    }

    private func write<T>(_ action: OfflineLibraryError.Action, _ request: () async throws -> T) async throws -> T {
        if state.route() == .offline {
            throw OfflineLibraryError.unavailableOffline(action)
        }
        do {
            let value = try await request()
            state.recordRequestSuccess()
            return value
        } catch {
            guard isConnectivityError(error) else {
                if error is JellyfinError { state.recordRequestSuccess() }
                throw error
            }
            state.recordConnectivityFailure()
            throw OfflineLibraryError.unavailableOffline(action)
        }
    }

    // MARK: Browsing

    public func albums(sortBy: String, sortOrder: String, startIndex: Int, limit: Int) async throws -> [Album] {
        try await read(
            online: { try await self.online.albums(sortBy: sortBy, sortOrder: sortOrder, startIndex: startIndex, limit: limit) },
            offline: { $0.albums(sortBy: sortBy, sortOrder: sortOrder, startIndex: startIndex, limit: limit) }
        )
    }

    public func album(id: String) async throws -> Album? {
        try await read(online: { try await self.online.album(id: id) }, offline: { $0.album(id: id) })
    }

    public func tracks(inAlbum albumID: String) async throws -> [Track] {
        try await read(
            online: { try await self.online.tracks(inAlbum: albumID) },
            offline: { $0.tracks(inAlbum: albumID) }
        )
    }

    public func artists(sortBy: String, startIndex: Int, limit: Int) async throws -> [Artist] {
        try await read(
            online: { try await self.online.artists(sortBy: sortBy, startIndex: startIndex, limit: limit) },
            offline: { $0.artists(sortBy: sortBy, startIndex: startIndex, limit: limit) }
        )
    }

    public func artist(id: String) async throws -> Artist? {
        try await read(online: { try await self.online.artist(id: id) }, offline: { $0.artist(id: id) })
    }

    public func albums(byArtist artistID: String) async throws -> [Album] {
        try await read(
            online: { try await self.online.albums(byArtist: artistID) },
            offline: { $0.albums(byArtist: artistID) }
        )
    }

    public func appearsOnAlbums(artistID: String) async throws -> [Album] {
        try await read(
            online: { try await self.online.appearsOnAlbums(artistID: artistID) },
            offline: { $0.appearsOnAlbums(artistID: artistID) }
        )
    }

    public func tracks(byArtist artistID: String) async throws -> [Track] {
        try await read(
            online: { try await self.online.tracks(byArtist: artistID) },
            offline: { $0.tracks(byArtist: artistID) }
        )
    }

    /// Offline there are no play counts; the artist's first downloaded tracks
    /// stand in for "top tracks".
    public func topTracks(byArtist artistID: String, limit: Int) async throws -> [Track] {
        try await read(
            online: { try await self.online.topTracks(byArtist: artistID, limit: limit) },
            offline: { Array($0.tracks(byArtist: artistID).prefix(max(limit, 0))) }
        )
    }

    /// Similarity needs the server; offline the shelf is simply empty.
    public func similarArtists(artistID: String, limit: Int) async throws -> [Artist] {
        try await read(
            online: { try await self.online.similarArtists(artistID: artistID, limit: limit) },
            offline: { _ in [] }
        )
    }

    public func favoriteTracks(limit: Int) async throws -> [Track] {
        try await read(
            online: { try await self.online.favoriteTracks(limit: limit) },
            offline: { $0.favoriteTracks(limit: limit) }
        )
    }

    public func favoriteAlbums(limit: Int) async throws -> [Album] {
        try await read(
            online: { try await self.online.favoriteAlbums(limit: limit) },
            offline: { $0.favoriteAlbums(limit: limit) }
        )
    }

    public func favoriteArtists(limit: Int) async throws -> [Artist] {
        try await read(
            online: { try await self.online.favoriteArtists(limit: limit) },
            offline: { $0.favoriteArtists(limit: limit) }
        )
    }

    public func tracks(inGenre genreID: String) async throws -> [Track] {
        // Offline genre ids never exist on the server; don't ask it.
        if genreID.hasPrefix(OfflineCatalog.genreIDPrefix) {
            return await catalog.offlineCatalog().tracks(inGenre: genreID)
        }
        return try await read(
            online: { try await self.online.tracks(inGenre: genreID) },
            offline: { $0.tracks(inGenre: genreID) }
        )
    }

    /// Lyrics are not stored with downloads; offline there are none.
    public func lyrics(forTrack trackID: String) async throws -> LyricsTimeline? {
        try await read(online: { try await self.online.lyrics(forTrack: trackID) }, offline: { _ in nil })
    }

    public func genres() async throws -> [Genre] {
        let notify = onGenresFetched
        return try await read(
            online: {
                let genres = try await self.online.genres()
                notify?(genres)
                return genres
            },
            offline: { $0.genres() }
        )
    }

    public func playlists() async throws -> [Playlist] {
        try await read(online: { try await self.online.playlists() }, offline: { $0.playlists() })
    }

    public func tracks(inPlaylist playlistID: String) async throws -> [Track] {
        try await read(
            online: { try await self.online.tracks(inPlaylist: playlistID) },
            offline: { $0.tracks(inPlaylist: playlistID) }
        )
    }

    public func recentlyAddedAlbums(limit: Int) async throws -> [Album] {
        try await read(
            online: { try await self.online.recentlyAddedAlbums(limit: limit) },
            offline: { $0.recentlyAddedAlbums(limit: limit) }
        )
    }

    /// Play history lives on the server; offline the shelf is empty.
    public func recentlyPlayedTracks(limit: Int) async throws -> [Track] {
        try await read(
            online: { try await self.online.recentlyPlayedTracks(limit: limit) },
            offline: { _ in [] }
        )
    }

    public func search(
        query: String,
        limit: Int
    ) async throws -> (tracks: [Track], albums: [Album], artists: [Artist], playlists: [Playlist]) {
        try await read(
            online: { try await self.online.search(query: query, limit: limit) },
            offline: { catalog in
                let results = catalog.search(query: query, limit: limit)
                return (results.tracks, results.albums, results.artists, results.playlists)
            }
        )
    }

    public func tracks(byIDs ids: [String]) async throws -> [Track] {
        try await read(online: { try await self.online.tracks(byIDs: ids) }, offline: { $0.tracks(byIDs: ids) })
    }

    // MARK: Mutations (online only)

    @discardableResult
    public func createPlaylist(name: String, itemIDs: [String]) async throws -> String {
        try await write(.editPlaylist) { try await self.online.createPlaylist(name: name, itemIDs: itemIDs) }
    }

    public func addToPlaylist(playlistID: String, itemIDs: [String]) async throws {
        try await write(.editPlaylist) { try await self.online.addToPlaylist(playlistID: playlistID, itemIDs: itemIDs) }
    }

    public func removeFromPlaylist(playlistID: String, entryIDs: [String]) async throws {
        try await write(.editPlaylist) {
            try await self.online.removeFromPlaylist(playlistID: playlistID, entryIDs: entryIDs)
        }
    }

    public func movePlaylistItem(playlistID: String, entryID: String, toIndex: Int) async throws {
        try await write(.editPlaylist) {
            try await self.online.movePlaylistItem(playlistID: playlistID, entryID: entryID, toIndex: toIndex)
        }
    }

    public func renamePlaylist(playlistID: String, name: String) async throws {
        try await write(.editPlaylist) { try await self.online.renamePlaylist(playlistID: playlistID, name: name) }
    }

    public func deletePlaylist(playlistID: String) async throws {
        try await write(.editPlaylist) { try await self.online.deletePlaylist(playlistID: playlistID) }
    }

    public func setPlaylistImage(playlistID: String, jpeg: Data) async throws {
        try await write(.editPlaylist) { try await self.online.setPlaylistImage(playlistID: playlistID, jpeg: jpeg) }
    }

    public func setFavorite(itemID: String, isFavorite: Bool) async throws {
        try await write(.changeFavorite) { try await self.online.setFavorite(itemID: itemID, isFavorite: isFavorite) }
    }
}
