import Foundation
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Jellyfin's built-in smart endpoints: Instant Mix, Similar, random
/// genre/year queries. Backs `JellyfinFallbackSonicProvider` (see SonicClient)
/// and the radio features in Phase 2.
public final class InstantMixAPI: @unchecked Sendable {
    private let client: JellyfinClient

    public init(session: JellyfinSession, transport: HTTPTransport = URLSessionTransport()) {
        self.client = JellyfinClient(session: session, transport: transport)
    }

    /// `/Items/{id}/InstantMix` — works with track/album/artist/genre/playlist
    /// seeds. Track IDs, each once, at most `limit`; a track seed comes first.
    ///
    /// The server is sloppier than that: for a track seed it puts the seed in
    /// front of a mix that contains the seed again, and returns `limit + 1`
    /// items.
    public func instantMix(seedID: String, limit: Int) async throws -> [String] {
        let items = try await client.items(path: "Items/\(seedID)/InstantMix", query: idQuery(limit: limit))
        return Array(Self.distinct(items.map(\.Id)).prefix(limit))
    }

    /// `/Items/{id}/Similar` — items of the seed's kind (artists for an
    /// artist, albums for an album, tracks for a track), never the seed.
    public func similarItems(to itemID: String, limit: Int) async throws -> [String] {
        let items = try await client.items(path: "Items/\(itemID)/Similar", query: idQuery(limit: limit))
        return Self.distinct(items.map(\.Id)).filter { !JellyfinClient.sameID($0, itemID) }
    }

    /// Only IDs are read: skip the media sources, user data and image tags
    /// the server would otherwise assemble for every item.
    private func idQuery(limit: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fields", value: "ParentId"),
            URLQueryItem(name: "enableUserData", value: "false"),
            URLQueryItem(name: "enableImages", value: "false"),
        ]
    }

    static func distinct(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    public func randomTracks(genre: String?, yearRange: ClosedRange<Int>?, limit: Int) async throws -> [String] {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "includeItemTypes", value: "Audio"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: "Random"),
        ] + idQuery(limit: limit)
        if let genre {
            // `genres` is pipe-delimited on the server: a "|" in a genre name
            // would split it, anything else (commas, "&", "+") is data.
            query.append(URLQueryItem(name: "genres", value: genre))
        }
        if let yearRange {
            // `years` is a comma-delimited list, there is no range parameter.
            query.append(URLQueryItem(name: "years", value: yearRange.map(String.init).joined(separator: ",")))
        }
        return try await client.items(query: query).map(\.Id)
    }
}
