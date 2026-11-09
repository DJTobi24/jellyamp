import Foundation
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Narrows a browse list. All parts are optional and combine with AND.
public struct BrowseFilter: Equatable, Sendable {
    public var genreID: String?
    public var favoritesOnly: Bool
    public var searchTerm: String?
    /// Tracks: any credit of this artist. Albums: this album artist.
    public var artistID: String?

    public init(genreID: String? = nil, favoritesOnly: Bool = false, searchTerm: String? = nil, artistID: String? = nil) {
        self.genreID = genreID
        self.favoritesOnly = favoritesOnly
        self.searchTerm = searchTerm
        self.artistID = artistID
    }

    public static let none = BrowseFilter()
}

public enum BrowseKind: String, Sendable {
    case albums, artists, tracks
}

public enum LibraryBrowseError: Error, Equatable {
    /// The list cannot be produced by this provider (e.g. the complete song
    /// list while offline).
    case unavailable
}

/// Paged, sortable access to the library for the browsing screens. Separate
/// from `MusicLibraryProviding`, whose list calls return whole collections:
/// on a 50,000-track library every list here is fetched a page at a time.
public protocol LibraryBrowsing: Sendable {
    func albumsPage(sort: LibrarySortQuery, filter: BrowseFilter, startIndex: Int, limit: Int) async throws -> Page<Album>
    func artistsPage(sort: LibrarySortQuery, filter: BrowseFilter, startIndex: Int, limit: Int) async throws -> Page<Artist>
    func tracksPage(sort: LibrarySortQuery, filter: BrowseFilter, startIndex: Int, limit: Int) async throws -> Page<Track>
    func playlistsPage(sort: LibrarySortQuery, filter: BrowseFilter, startIndex: Int, limit: Int) async throws -> Page<Playlist>
    func genresPage(startIndex: Int, limit: Int) async throws -> Page<Genre>
    func playlistTracksPage(playlistID: String, startIndex: Int, limit: Int) async throws -> Page<Track>
    /// Server offset of the first item at or after `letter` in the
    /// name-ascending list of `kind` (A–Z index).
    func alphabetOffset(of letter: String, kind: BrowseKind, filter: BrowseFilter) async throws -> Int
    /// The artist's own releases, with track counts, newest first.
    func discography(artistID: String) async throws -> [Album]
    /// Albums of other album artists that contain tracks by this artist.
    func appearsOn(artistID: String) async throws -> [Album]
    func playlist(id: String) async throws -> Playlist?
}

/// `LibraryBrowsing` against a Jellyfin server.
public final class LibraryBrowseAPI: LibraryBrowsing, @unchecked Sendable {
    private let session: JellyfinSession
    private let transport: HTTPTransport
    private let decoder = JSONDecoder()

    /// `ChildCount` is not part of Jellyfin's default item payload; without
    /// it albums and playlists report no track count.
    static let listFields = defaultFields + ",ChildCount"

    public init(session: JellyfinSession, transport: HTTPTransport = URLSessionTransport()) {
        self.session = session
        self.transport = transport
    }

    public func albumsPage(sort: LibrarySortQuery, filter: BrowseFilter, startIndex: Int, limit: Int) async throws -> Page<Album> {
        var query = itemsQuery(type: "MusicAlbum", sort: sort, filter: filter, startIndex: startIndex, limit: limit)
        if let artistID = filter.artistID { query.append(URLQueryItem(name: "albumArtistIds", value: artistID)) }
        let response = try await items(query)
        return Page(items: response.Items.map(DTOMapper.album(from:)), totalCount: response.TotalRecordCount)
    }

    public func artistsPage(sort: LibrarySortQuery, filter: BrowseFilter, startIndex: Int, limit: Int) async throws -> Page<Artist> {
        var query = [
            URLQueryItem(name: "sortBy", value: sort.sortBy),
            URLQueryItem(name: "sortOrder", value: sort.sortOrder),
            URLQueryItem(name: "startIndex", value: String(max(0, startIndex))),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "userId", value: session.userID ?? ""),
            URLQueryItem(name: "enableImageTypes", value: "Primary"),
        ]
        if filter.favoritesOnly { query.append(URLQueryItem(name: "isFavorite", value: "true")) }
        if let genreID = filter.genreID { query.append(URLQueryItem(name: "genreIds", value: genreID)) }
        if let term = filter.searchTerm { query.append(URLQueryItem(name: "searchTerm", value: term)) }
        let response: ItemsResponse = try await execute(session.request(path: "Artists/AlbumArtists", query: query))
        return Page(items: response.Items.map(DTOMapper.artist(from:)), totalCount: response.TotalRecordCount)
    }

    public func tracksPage(sort: LibrarySortQuery, filter: BrowseFilter, startIndex: Int, limit: Int) async throws -> Page<Track> {
        var query = itemsQuery(type: "Audio", sort: sort, filter: filter, startIndex: startIndex, limit: limit)
        if let artistID = filter.artistID { query.append(URLQueryItem(name: "artistIds", value: artistID)) }
        let response = try await items(query)
        return Page(items: response.Items.map(DTOMapper.track(from:)), totalCount: response.TotalRecordCount)
    }

    public func playlistsPage(sort: LibrarySortQuery, filter: BrowseFilter, startIndex: Int, limit: Int) async throws -> Page<Playlist> {
        let query = itemsQuery(type: "Playlist", sort: sort, filter: filter, startIndex: startIndex, limit: limit)
        let response = try await items(query)
        return Page(items: response.Items.map(Self.playlist(from:)), totalCount: response.TotalRecordCount)
    }

    public func genresPage(startIndex: Int, limit: Int) async throws -> Page<Genre> {
        let request = session.request(path: "MusicGenres", query: [
            URLQueryItem(name: "userId", value: session.userID ?? ""),
            URLQueryItem(name: "sortBy", value: "SortName"),
            URLQueryItem(name: "startIndex", value: String(max(0, startIndex))),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        let response: ItemsResponse = try await execute(request)
        return Page(items: response.Items.map { Genre(id: $0.Id, name: $0.Name ?? "") }, totalCount: response.TotalRecordCount)
    }

    public func playlistTracksPage(playlistID: String, startIndex: Int, limit: Int) async throws -> Page<Track> {
        let request = session.request(path: "Playlists/\(playlistID)/Items", query: [
            URLQueryItem(name: "userId", value: session.userID ?? ""),
            URLQueryItem(name: "fields", value: defaultFields),
            URLQueryItem(name: "startIndex", value: String(max(0, startIndex))),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        let response: ItemsResponse = try await execute(request)
        let tracks = response.Items.map { dto -> Track in
            var track = DTOMapper.track(from: dto)
            track.playlistEntryID = dto.PlaylistItemId
            return track
        }
        return Page(items: tracks, totalCount: response.TotalRecordCount)
    }

    public func alphabetOffset(of letter: String, kind: BrowseKind, filter: BrowseFilter) async throws -> Int {
        guard case .countBelow(let bound) = AlphabetIndex.offsetLookup(forLetter: letter) else { return 0 }
        switch kind {
        case .albums:
            // `limit=0` returns no rows but still the count of matches.
            var query = itemsQuery(type: "MusicAlbum", sort: AlbumSortOption.name.query(), filter: filter, startIndex: 0, limit: 0)
            query.append(URLQueryItem(name: "nameLessThan", value: bound))
            return try await items(query).TotalRecordCount ?? 0
        case .artists:
            var query = [
                URLQueryItem(name: "userId", value: session.userID ?? ""),
                URLQueryItem(name: "nameLessThan", value: bound),
                URLQueryItem(name: "limit", value: "0"),
            ]
            if filter.favoritesOnly { query.append(URLQueryItem(name: "isFavorite", value: "true")) }
            if let genreID = filter.genreID { query.append(URLQueryItem(name: "genreIds", value: genreID)) }
            let response: ItemsResponse = try await execute(session.request(path: "Artists/AlbumArtists", query: query))
            return response.TotalRecordCount ?? 0
        case .tracks:
            // `nameLessThan` compares the sort name, which for audio items is
            // the track number ("0001 - Title") — useless for titles. Binary
            // search over the title-sorted list instead.
            let sort = TrackSortOption.title.query()
            let total = try await items(itemsQuery(type: "Audio", sort: sort, filter: filter, startIndex: 0, limit: 0)).TotalRecordCount ?? 0
            return try await AlphabetIndex.firstIndex(count: total) { index in
                var probe = self.itemsQuery(type: "Audio", sort: sort, filter: filter, startIndex: index, limit: 1, fields: "")
                probe.append(URLQueryItem(name: "enableTotalRecordCount", value: "false"))
                probe.append(URLQueryItem(name: "enableUserData", value: "false"))
                probe.append(URLQueryItem(name: "enableImages", value: "false"))
                guard let name = try await self.items(probe).Items.first?.Name else { return false }
                return AlphabetIndex.binaryPrecedes(name, bound)
            }
        }
    }

    public func discography(artistID: String) async throws -> [Album] {
        let response = try await items([
            URLQueryItem(name: "albumArtistIds", value: artistID),
            URLQueryItem(name: "includeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: "ProductionYear,SortName"),
            URLQueryItem(name: "sortOrder", value: "Descending,Ascending"),
            URLQueryItem(name: "fields", value: Self.listFields),
        ])
        return response.Items.map(DTOMapper.album(from:))
    }

    public func appearsOn(artistID: String) async throws -> [Album] {
        // `contributingArtistIds` already means "credited on a track, but not
        // the album artist". Adding `excludeArtistIds` for the same artist
        // removes every match (verified on 10.10.7: always empty).
        let response = try await items([
            URLQueryItem(name: "contributingArtistIds", value: artistID),
            URLQueryItem(name: "includeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: "ProductionYear,SortName"),
            URLQueryItem(name: "sortOrder", value: "Descending,Ascending"),
            URLQueryItem(name: "fields", value: Self.listFields),
        ])
        return response.Items.map(DTOMapper.album(from:))
    }

    public func playlist(id: String) async throws -> Playlist? {
        let response = try await items([
            URLQueryItem(name: "ids", value: id),
            URLQueryItem(name: "fields", value: Self.listFields),
        ])
        return response.Items.first.map(Self.playlist(from:))
    }

    // MARK: - Plumbing

    private func itemsQuery(
        type: String,
        sort: LibrarySortQuery,
        filter: BrowseFilter,
        startIndex: Int,
        limit: Int,
        fields: String = LibraryBrowseAPI.listFields
    ) -> [URLQueryItem] {
        var query = [
            URLQueryItem(name: "includeItemTypes", value: type),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: sort.sortBy),
            URLQueryItem(name: "sortOrder", value: sort.sortOrder),
            URLQueryItem(name: "startIndex", value: String(max(0, startIndex))),
            URLQueryItem(name: "limit", value: String(max(0, limit))),
            URLQueryItem(name: "fields", value: fields),
            URLQueryItem(name: "enableImageTypes", value: "Primary"),
        ]
        if filter.favoritesOnly { query.append(URLQueryItem(name: "filters", value: "IsFavorite")) }
        if let genreID = filter.genreID { query.append(URLQueryItem(name: "genreIds", value: genreID)) }
        if let term = filter.searchTerm { query.append(URLQueryItem(name: "searchTerm", value: term)) }
        return query
    }

    private func items(_ query: [URLQueryItem]) async throws -> ItemsResponse {
        var fullQuery = query
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

    static func playlist(from dto: BaseItemDto) -> Playlist {
        Playlist(
            id: dto.Id,
            name: dto.Name ?? "",
            trackCount: dto.ChildCount,
            duration: dto.RunTimeTicks.map { Double($0) / 10_000_000 },
            imageTag: dto.ImageTags?["Primary"]
        )
    }
}

/// `LibraryBrowsing` on top of any `MusicLibraryProviding` — used when the
/// app runs against a decorated library (offline mode) instead of the live
/// server. Lists the wrapped provider can only return whole come back as a
/// single page; lists it cannot produce throw `LibraryBrowseError.unavailable`.
public struct LibraryProviderBrowser: LibraryBrowsing {
    private let library: MusicLibraryProviding
    /// Upper bound for the wrapped provider's un-paged favorites/search calls.
    private let singlePageLimit: Int

    public init(library: MusicLibraryProviding, singlePageLimit: Int = 500) {
        self.library = library
        self.singlePageLimit = singlePageLimit
    }

    public func albumsPage(sort: LibrarySortQuery, filter: BrowseFilter, startIndex: Int, limit: Int) async throws -> Page<Album> {
        if let term = filter.searchTerm {
            return try await single(startIndex) { try await library.search(query: term, limit: singlePageLimit).albums }
        }
        if filter.favoritesOnly {
            return try await single(startIndex) { try await library.favoriteAlbums(limit: singlePageLimit) }
        }
        if let artistID = filter.artistID {
            return try await single(startIndex) { try await library.albums(byArtist: artistID) }
        }
        guard filter.genreID == nil else { throw LibraryBrowseError.unavailable }
        // The wrapped call takes one sort order for all keys.
        let order = sort.sortOrder.split(separator: ",").first.map(String.init) ?? "Ascending"
        let items = try await library.albums(sortBy: sort.sortBy, sortOrder: order, startIndex: startIndex, limit: limit)
        return Page(items: items)
    }

    public func artistsPage(sort: LibrarySortQuery, filter: BrowseFilter, startIndex: Int, limit: Int) async throws -> Page<Artist> {
        if let term = filter.searchTerm {
            return try await single(startIndex) { try await library.search(query: term, limit: singlePageLimit).artists }
        }
        if filter.favoritesOnly {
            return try await single(startIndex) { try await library.favoriteArtists(limit: singlePageLimit) }
        }
        guard filter.genreID == nil else { throw LibraryBrowseError.unavailable }
        // The wrapped call has no sort order; only the first key applies.
        let sortBy = sort.sortBy.split(separator: ",").first.map(String.init) ?? "SortName"
        return Page(items: try await library.artists(sortBy: sortBy, startIndex: startIndex, limit: limit))
    }

    public func tracksPage(sort: LibrarySortQuery, filter: BrowseFilter, startIndex: Int, limit: Int) async throws -> Page<Track> {
        if let term = filter.searchTerm {
            return try await single(startIndex) { try await library.search(query: term, limit: singlePageLimit).tracks }
        }
        if filter.favoritesOnly {
            return try await single(startIndex) { try await library.favoriteTracks(limit: singlePageLimit) }
        }
        if let genreID = filter.genreID {
            return try await single(startIndex) { try await library.tracks(inGenre: genreID) }
        }
        if let artistID = filter.artistID {
            return try await single(startIndex) { try await library.tracks(byArtist: artistID) }
        }
        throw LibraryBrowseError.unavailable
    }

    public func playlistsPage(sort: LibrarySortQuery, filter: BrowseFilter, startIndex: Int, limit: Int) async throws -> Page<Playlist> {
        if let term = filter.searchTerm {
            return try await single(startIndex) { try await library.search(query: term, limit: singlePageLimit).playlists }
        }
        return try await single(startIndex) {
            try await library.playlists().sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    public func genresPage(startIndex: Int, limit: Int) async throws -> Page<Genre> {
        try await single(startIndex) { try await library.genres() }
    }

    public func playlistTracksPage(playlistID: String, startIndex: Int, limit: Int) async throws -> Page<Track> {
        try await single(startIndex) { try await library.tracks(inPlaylist: playlistID) }
    }

    public func alphabetOffset(of letter: String, kind: BrowseKind, filter: BrowseFilter) async throws -> Int {
        throw LibraryBrowseError.unavailable
    }

    public func discography(artistID: String) async throws -> [Album] {
        try await library.albums(byArtist: artistID)
    }

    public func appearsOn(artistID: String) async throws -> [Album] {
        try await library.appearsOnAlbums(artistID: artistID)
    }

    public func playlist(id: String) async throws -> Playlist? {
        try await library.playlists().first { $0.id == id }
    }

    /// A whole collection as page one; any later page is empty, which ends
    /// the list.
    private func single<Item: Sendable>(_ startIndex: Int, _ load: () async throws -> [Item]) async throws -> Page<Item> {
        guard startIndex == 0 else { return Page(items: [], totalCount: nil) }
        let items = try await load()
        return Page(items: items, totalCount: items.count)
    }
}
