import Foundation
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the UI needs from a music library. Implemented here against Jellyfin;
/// decorated with an offline filter in the app shell.
public protocol MusicLibraryProviding: Sendable {
    func albums(sortBy: String, sortOrder: String, startIndex: Int, limit: Int) async throws -> [Album]
    func album(id: String) async throws -> Album?
    func tracks(inAlbum albumID: String) async throws -> [Track]
    func artists(sortBy: String, startIndex: Int, limit: Int) async throws -> [Artist]
    func artist(id: String) async throws -> Artist?
    func albums(byArtist artistID: String) async throws -> [Album]
    func appearsOnAlbums(artistID: String) async throws -> [Album]
    func tracks(byArtist artistID: String) async throws -> [Track]
    func topTracks(byArtist artistID: String, limit: Int) async throws -> [Track]
    func similarArtists(artistID: String, limit: Int) async throws -> [Artist]
    func favoriteTracks(limit: Int) async throws -> [Track]
    func favoriteAlbums(limit: Int) async throws -> [Album]
    func favoriteArtists(limit: Int) async throws -> [Artist]
    func tracks(inGenre genreID: String) async throws -> [Track]
    func lyrics(forTrack trackID: String) async throws -> LyricsTimeline?
    func genres() async throws -> [Genre]
    @discardableResult
    func createPlaylist(name: String, itemIDs: [String]) async throws -> String
    func addToPlaylist(playlistID: String, itemIDs: [String]) async throws
    func playlists() async throws -> [Playlist]
    func tracks(inPlaylist playlistID: String) async throws -> [Track]
    func removeFromPlaylist(playlistID: String, entryIDs: [String]) async throws
    func movePlaylistItem(playlistID: String, entryID: String, toIndex: Int) async throws
    func renamePlaylist(playlistID: String, name: String) async throws
    func deletePlaylist(playlistID: String) async throws
    func setPlaylistImage(playlistID: String, jpeg: Data) async throws
    func recentlyAddedAlbums(limit: Int) async throws -> [Album]
    func recentlyPlayedTracks(limit: Int) async throws -> [Track]
    func search(query: String, limit: Int) async throws -> (tracks: [Track], albums: [Album], artists: [Artist], playlists: [Playlist])
    func tracks(byIDs ids: [String]) async throws -> [Track]
    func setFavorite(itemID: String, isFavorite: Bool) async throws
}

/// Fields we must request explicitly — Jellyfin omits media-source, genre and
/// child-count data from list responses by default (albums and playlists come
/// back without `ChildCount`, i.e. without a track count, otherwise).
let defaultFields = "MediaSources,Genres,DateCreated,ParentId,Overview,ChildCount"

/// Finds the moves that turn a playlist into the intended order using only
/// what every Jellyfin move endpoint does right — on a correct server and on
/// 10.10, whose `Move/{newIndex}` behaves like this (n entries):
///
/// - moving up (newIndex < old index): lands at `max(newIndex, 1)` — correct
///   unless the target is the top, which nothing can be moved to;
/// - moving down: lands at `min(newIndex + 1, n - 1)` — one too low unless
///   the target is the end;
/// - `newIndex >= n`: 500.
///
/// Reliable everywhere, therefore: moving up to an index ≥ 1, and moving the
/// top entry out of the way.
enum PlaylistReorder {
    /// One intended move needs at most three calls on 10.10; one more for slack.
    static let maxMoves = 4

    /// The next move towards `desired`, or nil when `current` already is it
    /// (or is no longer the same set of entries, in which case there is no
    /// telling what to do).
    static func nextMove(current: [String], desired: [String]) -> (entryID: String, index: Int)? {
        guard current != desired, current.count == desired.count, Set(current) == Set(desired),
              let index = current.indices.first(where: { current[$0] != desired[$0] })
        else { return nil }
        if index == 0, current.count > 1, current[1] == desired[0], let home = desired.firstIndex(of: current[0]) {
            // The right entry is second and cannot be raised: send the wrong
            // top entry down to where it belongs instead.
            return (current[0], home)
        }
        // Everything above `index` is in place, so this entry is below it.
        return (desired[index], index)
    }
}

public final class MusicLibraryAPI: MusicLibraryProviding, @unchecked Sendable {
    private let session: JellyfinSession
    private let transport: HTTPTransport
    private let client: JellyfinClient

    public init(session: JellyfinSession, transport: HTTPTransport = URLSessionTransport()) {
        self.session = session
        self.transport = transport
        self.client = JellyfinClient(session: session, transport: transport)
    }

    public func albums(sortBy: String = "SortName", sortOrder: String = "Ascending", startIndex: Int = 0, limit: Int = 100) async throws -> [Album] {
        let response = try await items(query: [
            URLQueryItem(name: "includeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: sortBy),
            URLQueryItem(name: "sortOrder", value: sortOrder),
            URLQueryItem(name: "startIndex", value: String(startIndex)),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return response.map(DTOMapper.album(from:))
    }

    public func album(id: String) async throws -> Album? {
        try await item(id: id, type: "MusicAlbum").map(DTOMapper.album(from:))
    }

    /// One item by ID, or nil if the server has no such item of that type.
    /// The answer is checked against the request: Jellyfin silently drops an
    /// `ids` value it cannot parse and then answers the *unfiltered* query —
    /// the user's root folders ("Music", "Playlists").
    private func item(id: String, type: String) async throws -> BaseItemDto? {
        guard !id.isEmpty else { return nil }
        let response = try await items(query: [URLQueryItem(name: "ids", value: id)])
        return response.first { JellyfinClient.sameID($0.Id, id) && $0.Type == type }
    }

    public func tracks(inAlbum albumID: String) async throws -> [Track] {
        // `albumIds`, not `parentId`: the parent of a track is its *folder*,
        // which is the album only as long as the album is one flat folder
        // (multi-disc rips keep "CD 1/", "CD 2/" below it), and an unknown
        // `parentId` is answered with 400 where this is an empty list.
        let response = try await items(query: [
            URLQueryItem(name: "albumIds", value: albumID),
            URLQueryItem(name: "includeItemTypes", value: "Audio"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: "ParentIndexNumber,IndexNumber,SortName"),
        ])
        return response.map(DTOMapper.track(from:))
    }

    public func artists(sortBy: String = "SortName", startIndex: Int = 0, limit: Int = 100) async throws -> [Artist] {
        // Through `items` for `fields=`: without it the artists carry no genres.
        let response = try await items(path: "Artists/AlbumArtists", query: [
            URLQueryItem(name: "sortBy", value: sortBy),
            URLQueryItem(name: "startIndex", value: String(startIndex)),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return response.map(DTOMapper.artist(from:))
    }

    /// Full artist item including the biography (`Overview`), which the list
    /// endpoints don't return.
    public func artist(id: String) async throws -> Artist? {
        try await item(id: id, type: "MusicArtist").map(DTOMapper.artist(from:))
    }

    public func albums(byArtist artistID: String) async throws -> [Album] {
        let response = try await items(query: [
            URLQueryItem(name: "albumArtistIds", value: artistID),
            URLQueryItem(name: "includeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: "ProductionYear,SortName"),
            URLQueryItem(name: "sortOrder", value: "Descending"),
        ])
        return response.map(DTOMapper.album(from:))
    }

    /// Albums the artist appears on without being the album artist (guest spots,
    /// compilations). That is exactly what `contributingArtistIds` means on the
    /// server. Do not combine it with `excludeArtistIds` for the same artist:
    /// that excludes every album the artist has a track on, i.e. everything.
    public func appearsOnAlbums(artistID: String) async throws -> [Album] {
        let response = try await items(query: [
            URLQueryItem(name: "contributingArtistIds", value: artistID),
            URLQueryItem(name: "includeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: "ProductionYear,SortName"),
            URLQueryItem(name: "sortOrder", value: "Descending"),
        ])
        return response.map(DTOMapper.album(from:))
    }

    /// The artist's most-played tracks (Jellyfin sorts by `PlayCount`).
    public func topTracks(byArtist artistID: String, limit: Int = 5) async throws -> [Track] {
        let response = try await items(query: [
            URLQueryItem(name: "artistIds", value: artistID),
            URLQueryItem(name: "includeItemTypes", value: "Audio"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: "PlayCount,SortName"),
            URLQueryItem(name: "sortOrder", value: "Descending"),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return response.map(DTOMapper.track(from:))
    }

    /// Similar artists via Jellyfin's metadata similarity (`/Items/{id}/Similar`).
    public func similarArtists(artistID: String, limit: Int = 12) async throws -> [Artist] {
        let response = try await items(path: "Items/\(artistID)/Similar", query: [
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return response
            .filter { $0.Type == "MusicArtist" && !JellyfinClient.sameID($0.Id, artistID) }
            .map(DTOMapper.artist(from:))
    }

    /// All tracks crediting this artist. Uses `artistIds` (any credit, not just
    /// album-artist) so artists whose songs aren't grouped into `MusicAlbum`
    /// items still surface their tracks.
    public func tracks(byArtist artistID: String) async throws -> [Track] {
        let response = try await items(query: [
            URLQueryItem(name: "artistIds", value: artistID),
            URLQueryItem(name: "includeItemTypes", value: "Audio"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: "Album,ParentIndexNumber,IndexNumber"),
        ])
        return response.map(DTOMapper.track(from:))
    }

    /// Creates a playlist seeded with the given tracks; returns its new ID.
    @discardableResult
    public func createPlaylist(name: String, itemIDs: [String]) async throws -> String {
        struct CreateResponse: Decodable { let Id: String }
        // As a JSON body (`CreatePlaylistDto`), not as query parameters: a
        // queue saved as a playlist easily has more IDs than fit in a URL.
        var payload: [String: Any] = ["Name": name, "Ids": itemIDs, "MediaType": "Audio"]
        if let userID = session.userID {
            payload["UserId"] = userID
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let request = client.request(path: "Playlists", method: "POST", body: body)
        let response: CreateResponse = try await client.decode(from: request)
        return response.Id
    }

    /// Appends tracks to an existing playlist. Jellyfin 10.10 keeps a track
    /// only once per playlist: IDs that are already in it are ignored.
    public func addToPlaylist(playlistID: String, itemIDs: [String]) async throws {
        // This endpoint only takes the IDs in the query string.
        for batch in JellyfinClient.batches(of: itemIDs) {
            try await sendExpectingSuccess(client.request(
                path: "Playlists/\(playlistID)/Items",
                query: [URLQueryItem(name: "ids", value: batch.joined(separator: ","))] + client.userQuery,
                method: "POST"
            ))
        }
    }

    public func removeFromPlaylist(playlistID: String, entryIDs: [String]) async throws {
        for batch in JellyfinClient.batches(of: entryIDs) {
            try await sendExpectingSuccess(client.request(
                path: "Playlists/\(playlistID)/Items",
                query: [URLQueryItem(name: "entryIds", value: batch.joined(separator: ","))],
                method: "DELETE"
            ))
        }
    }

    /// Moves a playlist entry so that it ends up at position `toIndex` (0-based,
    /// counted in the playlist as it is after the move; clamped to its end).
    ///
    /// Jellyfin's move endpoint cannot be trusted with that on its own. On
    /// 10.10 an entry moved down lands one slot too low, nothing can be moved
    /// to the top (it lands second), and an index past the end is a 500. So
    /// every move is read back and followed by corrective moves until the
    /// order is the intended one (`PlaylistReorder`): one call on a server
    /// that moves correctly, at most three on 10.10.
    public func movePlaylistItem(playlistID: String, entryID: String, toIndex: Int) async throws {
        var current = try await playlistEntries(playlistID)
        guard let from = current.firstIndex(where: { JellyfinClient.sameID($0.entryID, entryID) }) else {
            throw JellyfinError.notFound
        }
        let target = min(max(toIndex, 0), current.count - 1)
        guard from != target else { return }
        var desired = current
        desired.insert(desired.remove(at: from), at: target)

        var move: (entryID: String, index: Int)? = (current[from].entryID, target)
        var attempts = 0
        while let step = move, attempts < PlaylistReorder.maxMoves {
            attempts += 1
            try await sendExpectingSuccess(client.request(
                path: "Playlists/\(playlistID)/Items/\(step.entryID)/Move/\(step.index)",
                method: "POST"
            ))
            current = try await playlistEntries(playlistID)
            move = PlaylistReorder.nextMove(current: current.map(\.entryID), desired: desired.map(\.entryID))
        }
        guard move != nil else { return }
        // A server that moves in a way we do not know: write the order
        // outright. Only as the last resort — on 10.10 this queues a metadata
        // refresh of the playlist that silently undoes whatever changes it in
        // the next moment (another reorder, a removal, a rename).
        let body = try JSONSerialization.data(withJSONObject: ["Ids": desired.map(\.itemID)])
        try await sendExpectingSuccess(client.request(path: "Playlists/\(playlistID)", method: "POST", body: body))
    }

    private func playlistEntries(_ playlistID: String) async throws -> [(entryID: String, itemID: String)] {
        let entries = try await items(path: "Playlists/\(playlistID)/Items", query: [
            URLQueryItem(name: "fields", value: "ParentId"),
            URLQueryItem(name: "enableUserData", value: "false"),
            URLQueryItem(name: "enableImages", value: "false"),
        ])
        return entries.map { ($0.PlaylistItemId ?? $0.Id, $0.Id) }
    }

    public func renamePlaylist(playlistID: String, name: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["Name": name])
        try await sendExpectingSuccess(client.request(
            path: "Playlists/\(playlistID)",
            method: "POST",
            body: body
        ))
    }

    public func deletePlaylist(playlistID: String) async throws {
        try await sendExpectingSuccess(client.request(path: "Items/\(playlistID)", method: "DELETE"))
    }

    public func setPlaylistImage(playlistID: String, jpeg: Data) async throws {
        var request = client.request(
            path: "Items/\(playlistID)/Images/Primary",
            method: "POST",
            timeout: JellyfinClient.uploadTimeout
        )
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        // Jellyfin reads the image upload body as base64.
        request.httpBody = jpeg.base64EncodedData()
        try await sendExpectingSuccess(request)
    }

    private func sendExpectingSuccess(_ request: URLRequest) async throws {
        try await client.send(request)
    }

    /// The user's saved ("favorited") albums.
    public func favoriteAlbums(limit: Int = 500) async throws -> [Album] {
        let response = try await items(query: [
            URLQueryItem(name: "filters", value: "IsFavorite"),
            URLQueryItem(name: "includeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: "SortName"),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return response.map(DTOMapper.album(from:))
    }

    /// The user's followed ("favorited") album-artists.
    public func favoriteArtists(limit: Int = 500) async throws -> [Artist] {
        let response = try await items(path: "Artists/AlbumArtists", query: [
            URLQueryItem(name: "isFavorite", value: "true"),
            URLQueryItem(name: "sortBy", value: "SortName"),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return response.map(DTOMapper.artist(from:))
    }

    /// All tracks in a music genre.
    public func tracks(inGenre genreID: String) async throws -> [Track] {
        let response = try await items(query: [
            URLQueryItem(name: "genreIds", value: genreID),
            URLQueryItem(name: "includeItemTypes", value: "Audio"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: "Album,ParentIndexNumber,IndexNumber"),
        ])
        return response.map(DTOMapper.track(from:))
    }

    /// The user's favorited ("liked") tracks.
    public func favoriteTracks(limit: Int = 500) async throws -> [Track] {
        let response = try await items(query: [
            URLQueryItem(name: "filters", value: "IsFavorite"),
            URLQueryItem(name: "includeItemTypes", value: "Audio"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: "SortName"),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return response.map(DTOMapper.track(from:))
    }

    /// Synced or plain lyrics for a track (Jellyfin 10.9+), or nil if none.
    public func lyrics(forTrack trackID: String) async throws -> LyricsTimeline? {
        try await LyricsAPI(session: session, transport: transport).lyrics(forTrack: trackID)
    }

    public func genres() async throws -> [Genre] {
        // `/MusicGenres` is the music-specific endpoint; the generic `/Genres`
        // with includeItemTypes=Audio returns nothing on Jellyfin.
        let request = client.request(path: "MusicGenres", query: [
            URLQueryItem(name: "sortBy", value: "SortName"),
        ] + client.userQuery)
        let response = try await execute(request).Items
        return response.map { Genre(id: $0.Id, name: $0.Name ?? "") }
    }

    public func playlists() async throws -> [Playlist] {
        let response = try await items(query: [
            URLQueryItem(name: "includeItemTypes", value: "Playlist"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: "SortName"),
        ])
        return response.map(DTOMapper.playlist(from:))
    }

    public func tracks(inPlaylist playlistID: String) async throws -> [Track] {
        let response = try await items(path: "Playlists/\(playlistID)/Items", query: [])
        return response.map { dto in
            var track = DTOMapper.track(from: dto)
            track.playlistEntryID = dto.PlaylistItemId
            return track
        }
    }

    public func recentlyAddedAlbums(limit: Int = 20) async throws -> [Album] {
        let request = client.request(path: "Items/Latest", query: [
            URLQueryItem(name: "includeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "limit", value: String(limit)),
            // Like `/Items`, it leaves genres out unless asked.
            URLQueryItem(name: "fields", value: defaultFields),
        ] + client.userQuery)
        // /Items/Latest returns a bare array, not an ItemsResponse envelope.
        let dtos: LossyArray<BaseItemDto> = try await client.decode(from: request)
        return dtos.elements.map(DTOMapper.album(from:))
    }

    public func recentlyPlayedTracks(limit: Int = 20) async throws -> [Track] {
        let response = try await items(query: [
            URLQueryItem(name: "includeItemTypes", value: "Audio"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: "DatePlayed"),
            URLQueryItem(name: "sortOrder", value: "Descending"),
            URLQueryItem(name: "filters", value: "IsPlayed"),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return response.map(DTOMapper.track(from:))
    }

    public func search(query: String, limit: Int = 20) async throws -> (tracks: [Track], albums: [Album], artists: [Artist], playlists: [Playlist]) {
        // The server matches the term as typed: a trailing space (which the
        // keyboard adds after every autocompleted word) finds nothing.
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return ([], [], [], []) }
        // One request per kind so each kind gets its own `limit`; they are
        // independent, so they run side by side.
        @Sendable func found(_ type: String) async throws -> [BaseItemDto] {
            try await self.items(query: [
                URLQueryItem(name: "searchTerm", value: term),
                URLQueryItem(name: "includeItemTypes", value: type),
                URLQueryItem(name: "recursive", value: "true"),
                URLQueryItem(name: "limit", value: String(limit)),
            ])
        }
        async let trackItems = found("Audio")
        async let albumItems = found("MusicAlbum")
        async let artistItems = found("MusicArtist")
        async let playlistItems = found("Playlist")
        return try await (
            tracks: trackItems.map(DTOMapper.track(from:)),
            albums: albumItems.map(DTOMapper.album(from:)),
            artists: artistItems.map(DTOMapper.artist(from:)),
            playlists: playlistItems.map(DTOMapper.playlist(from:))
        )
    }

    public func tracks(byIDs ids: [String]) async throws -> [Track] {
        // Each distinct ID once, in URL-length-safe batches (a few hundred
        // comma-joined GUIDs are a 414), then back into the requested order:
        // duplicates stay duplicates, unknown IDs drop out.
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        let response = try await client.items(ids: unique)
        let byID = Dictionary(response.map { ($0.Id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }.map(DTOMapper.track(from:))
    }

    public func setFavorite(itemID: String, isFavorite: Bool) async throws {
        guard let userID = session.userID else { throw JellyfinError.notAuthenticated }
        let method = isFavorite ? "POST" : "DELETE"
        do {
            // The documented route since 10.9.
            try await sendExpectingSuccess(client.request(
                path: "UserFavoriteItems/\(itemID)", query: client.userQuery, method: method))
        } catch JellyfinError.notFound {
            // 404 is "no such item" on 10.9+ and "no such route" before; the
            // legacy route (undocumented but still served by 10.10) tells
            // them apart: it works on old servers and is a 404 for a missing
            // item everywhere.
            try await sendExpectingSuccess(client.request(
                path: "Users/\(userID)/FavoriteItems/\(itemID)", method: method))
        }
    }

    // MARK: - Plumbing

    private func items(path: String = "Items", query: [URLQueryItem]) async throws -> [BaseItemDto] {
        try await client.items(path: path, query: query)
    }

    private func execute(_ request: URLRequest) async throws -> ItemsResponse {
        try await client.decode(from: request)
    }
}
