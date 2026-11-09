import Foundation
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Jellyfin's built-in smart endpoints: Instant Mix, Similar, random
/// genre/year queries. Backs `JellyfinFallbackSonicProvider` (see SonicClient)
/// and the radio features in Phase 2.
public final class InstantMixAPI: @unchecked Sendable {
    private let session: JellyfinSession
    private let client: JellyfinClient

    public init(session: JellyfinSession, transport: HTTPTransport = URLSessionTransport()) {
        self.session = session
        self.client = JellyfinClient(session: session, transport: transport)
    }

    /// `/Items/{id}/InstantMix` — works with track/album/artist/genre/playlist seeds.
    public func instantMix(seedID: String, limit: Int) async throws -> [String] {
        let request = client.request(path: "Items/\(seedID)/InstantMix", query: [
            URLQueryItem(name: "userId", value: session.userID ?? ""),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        let response: ItemsResponse = try await execute(request)
        return response.Items.map(\.Id)
    }

    public func similarItems(to itemID: String, limit: Int) async throws -> [String] {
        let request = client.request(path: "Items/\(itemID)/Similar", query: [
            URLQueryItem(name: "userId", value: session.userID ?? ""),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        let response: ItemsResponse = try await execute(request)
        return response.Items.map(\.Id)
    }

    public func randomTracks(genre: String?, yearRange: ClosedRange<Int>?, limit: Int) async throws -> [String] {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "includeItemTypes", value: "Audio"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: "Random"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "userId", value: session.userID ?? ""),
        ]
        if let genre {
            query.append(URLQueryItem(name: "genres", value: genre))
        }
        if let yearRange {
            query.append(URLQueryItem(name: "years", value: yearRange.map(String.init).joined(separator: ",")))
        }
        let response: ItemsResponse = try await execute(client.request(path: "Items", query: query))
        return response.Items.map(\.Id)
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        try await client.decode(from: request)
    }
}
