import Foundation
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What the UI needs from a music library. Implemented here against Jellyfin;
/// decorated with an offline filter in the app shell.
public protocol MusicLibraryProviding: Sendable {
    func albums(sortBy: String, startIndex: Int, limit: Int) async throws -> [Album]
    func album(id: String) async throws -> Album?
    func tracks(inAlbum albumID: String) async throws -> [Track]
    func artists(startIndex: Int, limit: Int) async throws -> [Artist]
    func albums(byArtist artistID: String) async throws -> [Album]
    func tracks(byArtist artistID: String) async throws -> [Track]
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
    func recentlyAddedAlbums(limit: Int) async throws -> [Album]
    func recentlyPlayedTracks(limit: Int) async throws -> [Track]
    func search(query: String, limit: Int) async throws -> (tracks: [Track], albums: [Album], artists: [Artist])
    func tracks(byIDs ids: [String]) async throws -> [Track]
    func setFavorite(itemID: String, isFavorite: Bool) async throws
}

/// Fields we must request explicitly — Jellyfin omits media-source and genre
/// data from list responses by default.
let defaultFields = "MediaSources,Genres,DateCreated,ParentId,Overview"

public final class MusicLibraryAPI: MusicLibraryProviding, @unchecked Sendable {
    private let session: JellyfinSession
    private let transport: HTTPTransport
    private let decoder = JSONDecoder()

    public init(session: JellyfinSession, transport: HTTPTransport = URLSessionTransport()) {
        self.session = session
        self.transport = transport
    }

    public func albums(sortBy: String = "SortName", startIndex: Int = 0, limit: Int = 100) async throws -> [Album] {
        let response = try await items(query: [
            URLQueryItem(name: "includeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: sortBy),
            URLQueryItem(name: "startIndex", value: String(startIndex)),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return response.Items.map(DTOMapper.album(from:))
    }

    public func album(id: String) async throws -> Album? {
        let response = try await items(query: [
            URLQueryItem(name: "ids", value: id),
            URLQueryItem(name: "includeItemTypes", value: "MusicAlbum"),
        ])
        return response.Items.first.map(DTOMapper.album(from:))
    }

    public func tracks(inAlbum albumID: String) async throws -> [Track] {
        let response = try await items(query: [
            URLQueryItem(name: "parentId", value: albumID),
            URLQueryItem(name: "includeItemTypes", value: "Audio"),
            URLQueryItem(name: "sortBy", value: "ParentIndexNumber,IndexNumber"),
        ])
        return response.Items.map(DTOMapper.track(from:))
    }

    public func artists(startIndex: Int = 0, limit: Int = 100) async throws -> [Artist] {
        let request = session.request(path: "Artists/AlbumArtists", query: [
            URLQueryItem(name: "startIndex", value: String(startIndex)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "userId", value: session.userID ?? ""),
        ])
        let response: ItemsResponse = try await execute(request)
        return response.Items.map(DTOMapper.artist(from:))
    }

    public func albums(byArtist artistID: String) async throws -> [Album] {
        let response = try await items(query: [
            URLQueryItem(name: "albumArtistIds", value: artistID),
            URLQueryItem(name: "includeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: "ProductionYear,SortName"),
        ])
        return response.Items.map(DTOMapper.album(from:))
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
        return response.Items.map(DTOMapper.track(from:))
    }

    /// Creates a playlist seeded with the given tracks; returns its new ID.
    @discardableResult
    public func createPlaylist(name: String, itemIDs: [String]) async throws -> String {
        struct CreateResponse: Decodable { let Id: String }
        let request = session.request(
            path: "Playlists",
            query: [
                URLQueryItem(name: "name", value: name),
                URLQueryItem(name: "userId", value: session.userID ?? ""),
                URLQueryItem(name: "ids", value: itemIDs.joined(separator: ",")),
                URLQueryItem(name: "mediaType", value: "Audio"),
            ],
            method: "POST"
        )
        let response: CreateResponse = try await execute(request)
        return response.Id
    }

    /// Appends tracks to an existing playlist.
    public func addToPlaylist(playlistID: String, itemIDs: [String]) async throws {
        let request = session.request(
            path: "Playlists/\(playlistID)/Items",
            query: [
                URLQueryItem(name: "ids", value: itemIDs.joined(separator: ",")),
                URLQueryItem(name: "userId", value: session.userID ?? ""),
            ],
            method: "POST"
        )
        let (_, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw JellyfinError.serverError(status: response.statusCode)
        }
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
        return response.Items.map(DTOMapper.album(from:))
    }

    /// The user's followed ("favorited") album-artists.
    public func favoriteArtists(limit: Int = 500) async throws -> [Artist] {
        let request = session.request(path: "Artists/AlbumArtists", query: [
            URLQueryItem(name: "isFavorite", value: "true"),
            URLQueryItem(name: "userId", value: session.userID ?? ""),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        let response: ItemsResponse = try await execute(request)
        return response.Items.map(DTOMapper.artist(from:))
    }

    /// All tracks in a music genre.
    public func tracks(inGenre genreID: String) async throws -> [Track] {
        let response = try await items(query: [
            URLQueryItem(name: "genreIds", value: genreID),
            URLQueryItem(name: "includeItemTypes", value: "Audio"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: "Album,ParentIndexNumber,IndexNumber"),
        ])
        return response.Items.map(DTOMapper.track(from:))
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
        return response.Items.map(DTOMapper.track(from:))
    }

    /// Synced or plain lyrics for a track (Jellyfin 10.9+), or nil if none.
    public func lyrics(forTrack trackID: String) async throws -> LyricsTimeline? {
        try await LyricsAPI(session: session, transport: transport).lyrics(forTrack: trackID)
    }

    public func genres() async throws -> [Genre] {
        // `/MusicGenres` is the music-specific endpoint; the generic `/Genres`
        // with includeItemTypes=Audio returns nothing on Jellyfin.
        let request = session.request(path: "MusicGenres", query: [
            URLQueryItem(name: "userId", value: session.userID ?? ""),
            URLQueryItem(name: "sortBy", value: "SortName"),
        ])
        let response: ItemsResponse = try await execute(request)
        return response.Items.map { Genre(id: $0.Id, name: $0.Name ?? "") }
    }

    public func playlists() async throws -> [Playlist] {
        let response = try await items(query: [
            URLQueryItem(name: "includeItemTypes", value: "Playlist"),
            URLQueryItem(name: "recursive", value: "true"),
        ])
        return response.Items.map {
            Playlist(
                id: $0.Id,
                name: $0.Name ?? "",
                trackCount: $0.ChildCount,
                duration: $0.RunTimeTicks.map { Double($0) / 10_000_000 },
                imageTag: $0.ImageTags?["Primary"]
            )
        }
    }

    public func tracks(inPlaylist playlistID: String) async throws -> [Track] {
        let request = session.request(path: "Playlists/\(playlistID)/Items", query: [
            URLQueryItem(name: "userId", value: session.userID ?? ""),
            URLQueryItem(name: "fields", value: defaultFields),
        ])
        let response: ItemsResponse = try await execute(request)
        return response.Items.map(DTOMapper.track(from:))
    }

    public func recentlyAddedAlbums(limit: Int = 20) async throws -> [Album] {
        let request = session.request(path: "Items/Latest", query: [
            URLQueryItem(name: "includeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "userId", value: session.userID ?? ""),
        ])
        // /Items/Latest returns a bare array, not an ItemsResponse envelope.
        let dtos: [BaseItemDto] = try await execute(request)
        return dtos.map(DTOMapper.album(from:))
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
        return response.Items.map(DTOMapper.track(from:))
    }

    public func search(query: String, limit: Int = 20) async throws -> (tracks: [Track], albums: [Album], artists: [Artist]) {
        func searchQuery(type: String) -> [URLQueryItem] {
            [
                URLQueryItem(name: "searchTerm", value: query),
                URLQueryItem(name: "includeItemTypes", value: type),
                URLQueryItem(name: "recursive", value: "true"),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
        }
        let trackItems = try await items(query: searchQuery(type: "Audio"))
        let albumItems = try await items(query: searchQuery(type: "MusicAlbum"))
        let artistItems = try await items(query: searchQuery(type: "MusicArtist"))
        return (
            tracks: trackItems.Items.map(DTOMapper.track(from:)),
            albums: albumItems.Items.map(DTOMapper.album(from:)),
            artists: artistItems.Items.map(DTOMapper.artist(from:))
        )
    }

    public func tracks(byIDs ids: [String]) async throws -> [Track] {
        guard !ids.isEmpty else { return [] }
        let response = try await items(query: [
            URLQueryItem(name: "ids", value: ids.joined(separator: ",")),
        ])
        // Preserve requested order — Jellyfin returns library order.
        let byID = Dictionary(uniqueKeysWithValues: response.Items.map { ($0.Id, $0) })
        return ids.compactMap { byID[$0] }.map(DTOMapper.track(from:))
    }

    public func setFavorite(itemID: String, isFavorite: Bool) async throws {
        guard let userID = session.userID else { throw JellyfinError.notAuthenticated }
        let request = session.request(
            path: "Users/\(userID)/FavoriteItems/\(itemID)",
            method: isFavorite ? "POST" : "DELETE"
        )
        let (_, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw JellyfinError.serverError(status: response.statusCode)
        }
    }

    // MARK: - Plumbing

    private func items(query: [URLQueryItem]) async throws -> ItemsResponse {
        var fullQuery = query
        if !query.contains(where: { $0.name == "fields" }) {
            fullQuery.append(URLQueryItem(name: "fields", value: defaultFields))
        }
        if let userID = session.userID {
            fullQuery.append(URLQueryItem(name: "userId", value: userID))
        }
        return try await execute(session.request(path: "Items", query: fullQuery))
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200..<300:
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw JellyfinError.invalidResponse
            }
        case 401:
            throw JellyfinError.unauthorized
        case 404:
            throw JellyfinError.notFound
        default:
            throw JellyfinError.serverError(status: response.statusCode)
        }
    }
}
