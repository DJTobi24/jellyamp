import Foundation
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Batched lookups the sonic features need on top of `MusicLibraryProviding`:
/// resolving ID lists (similar albums/artists, mixes, adventures) in as few
/// requests as possible, the library's year range for decade stations, and
/// random picks returned as full tracks for the Jellyfin-only stations.
///
/// Verified against Jellyfin 10.10: `/Items?ids=` resolves `MusicAlbum`,
/// `MusicArtist` and `Audio` items alike and returns them in library order.
public final class LibraryLookupAPI: @unchecked Sendable {
    /// IDs per request. 32-char IDs put ~2.7 kB into the query string at this
    /// size — comfortably below common proxy URL limits (4–8 kB).
    static let chunkSize = 80

    private let session: JellyfinSession
    private let transport: HTTPTransport
    private let decoder = JSONDecoder()

    public init(session: JellyfinSession, transport: HTTPTransport = URLSessionTransport()) {
        self.session = session
        self.transport = transport
    }

    /// Albums for the given IDs, in the requested order; unknown IDs drop out.
    public func albums(byIDs ids: [String]) async throws -> [Album] {
        try await resolve(ids: ids).map(DTOMapper.album(from:))
    }

    /// Artists for the given IDs, in the requested order; unknown IDs drop out.
    public func artists(byIDs ids: [String]) async throws -> [Artist] {
        try await resolve(ids: ids).map(DTOMapper.artist(from:))
    }

    /// Like `MusicLibraryAPI.tracks(byIDs:)` but split into several requests
    /// for long lists (a mix or station batch can carry hundreds of IDs).
    public func tracks(byIDs ids: [String]) async throws -> [Track] {
        try await resolve(ids: ids).map(DTOMapper.track(from:))
    }

    /// Distinct production years of the user's audio items, ascending. Uses
    /// the legacy filters endpoint, which is the only one that returns the
    /// year list without paging through the library.
    public func productionYears() async throws -> [Int] {
        struct Filters: Decodable {
            var Years: [Int]?
        }
        let request = session.request(path: "Items/Filters", query: [
            URLQueryItem(name: "userId", value: session.userID ?? ""),
            URLQueryItem(name: "includeItemTypes", value: "Audio"),
        ])
        let filters: Filters = try await execute(request)
        return Array(Set(filters.Years ?? [])).sorted()
    }

    /// Random tracks, optionally narrowed to a genre and/or a span of years —
    /// the Jellyfin-only stand-in for sonic stations.
    public func randomTracks(genre: String? = nil, years: ClosedRange<Int>? = nil, limit: Int) async throws -> [Track] {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "includeItemTypes", value: "Audio"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: "Random"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: defaultFields),
            URLQueryItem(name: "userId", value: session.userID ?? ""),
        ]
        if let genre {
            query.append(URLQueryItem(name: "genres", value: genre))
        }
        if let years {
            query.append(URLQueryItem(name: "years", value: years.map(String.init).joined(separator: ",")))
        }
        let response: ItemsResponse = try await execute(session.request(path: "Items", query: query))
        return response.Items.map(DTOMapper.track(from:))
    }

    // MARK: - Plumbing

    /// Fetches the items chunk by chunk and restores the requested order
    /// (Jellyfin answers in library order). Duplicate IDs are resolved once.
    private func resolve(ids: [String]) async throws -> [BaseItemDto] {
        var seen = Set<String>()
        let unique = ids.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !unique.isEmpty else { return [] }

        var byID: [String: BaseItemDto] = [:]
        var start = 0
        while start < unique.count {
            let chunk = unique[start..<min(start + Self.chunkSize, unique.count)]
            start += Self.chunkSize
            let request = session.request(path: "Items", query: [
                URLQueryItem(name: "ids", value: chunk.joined(separator: ",")),
                URLQueryItem(name: "fields", value: defaultFields),
                URLQueryItem(name: "userId", value: session.userID ?? ""),
            ])
            let response: ItemsResponse = try await execute(request)
            for item in response.Items {
                byID[item.Id] = item
            }
        }
        return unique.compactMap { byID[$0] }
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
