import Foundation
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Wire-format DTOs matching docs/SONIC-API.md. Internal: the app sees only
/// `SonicProviding` types.
struct InfoResponse: Codable {
    var version: String
    var jellyfinServerId: String
    var tracksTotal: Int
    var tracksAnalyzed: Int
    var capabilities: [String]
}

struct SimilarResponse: Codable {
    struct Item: Codable {
        var itemId: String
        var distance: Double
    }
    var items: [Item]
}

struct AdventureResponse: Codable {
    struct Item: Codable {
        var itemId: String
        var position: Int
        var distance: Double
    }
    var items: [Item]
}

struct MixesResponse: Codable {
    struct Mix: Codable {
        var id: String
        var title: String
        var description: String?
        var seedItemIds: [String]
        var itemIds: [String]
    }
    var mixes: [Mix]
}

struct StationRequest: Codable {
    var type: String
    var seed: String
    var count: Int
}

struct StationResponse: Codable {
    var itemIds: [String]
}

struct LoudnessResponse: Codable {
    var integratedLufs: Double
    var truePeak: Double
}

/// REST client for jellyamp-server (docs/SONIC-API.md).
public final class SonicAPIClient: SonicProviding, @unchecked Sendable {
    private let baseURL: URL
    private let apiKey: String
    private let transport: HTTPTransport
    private let decoder = JSONDecoder()

    public init(baseURL: URL, apiKey: String, transport: HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.transport = transport
    }

    public var capabilities: SonicCapabilities {
        get async {
            guard let info = try? await fetchInfo() else {
                return SonicCapabilities(capabilities: [])
            }
            return SonicCapabilities(
                capabilities: Set(info.capabilities.compactMap(SonicCapability.init(rawValue:))),
                analysisProgress: .init(tracksAnalyzed: info.tracksAnalyzed, tracksTotal: info.tracksTotal)
            )
        }
    }

    func fetchInfo() async throws -> InfoResponse {
        try await get("info")
    }

    public func similarTracks(to itemID: String, limit: Int) async throws -> [SimilarItem] {
        try await similar(kind: "tracks", id: itemID, limit: limit)
    }

    public func similarArtists(to artistID: String, limit: Int) async throws -> [SimilarItem] {
        try await similar(kind: "artists", id: artistID, limit: limit)
    }

    public func similarAlbums(to albumID: String, limit: Int) async throws -> [SimilarItem] {
        try await similar(kind: "albums", id: albumID, limit: limit)
    }

    private func similar(kind: String, id: String, limit: Int) async throws -> [SimilarItem] {
        let response: SimilarResponse = try await get("similar/\(kind)/\(id)", query: [URLQueryItem(name: "limit", value: String(limit))])
        return response.items.map { SimilarItem(itemID: $0.itemId, distance: $0.distance) }
    }

    public func adventure(from: String, to: String, steps: Int) async throws -> [String] {
        let response: AdventureResponse = try await get("adventure", query: [
            URLQueryItem(name: "from", value: from),
            URLQueryItem(name: "to", value: to),
            URLQueryItem(name: "steps", value: String(steps)),
        ])
        return response.items.sorted { $0.position < $1.position }.map(\.itemId)
    }

    public func mixes(forUser userID: String) async throws -> [MixDescriptor] {
        let response: MixesResponse = try await get("mixes", query: [URLQueryItem(name: "userId", value: userID)])
        return response.mixes.map {
            MixDescriptor(id: $0.id, title: $0.title, description: $0.description, seedItemIDs: $0.seedItemIds, itemIDs: $0.itemIds)
        }
    }

    public func station(type: StationType, seed: String, count: Int) async throws -> [String] {
        let body = StationRequest(type: type.rawValue, seed: seed, count: count)
        let response: StationResponse = try await post("stations", body: body)
        return response.itemIds
    }

    public func loudness(forTrack itemID: String) async throws -> (integratedLufs: Double, truePeak: Double) {
        let response: LoudnessResponse = try await get("loudness/\(itemID)")
        return (response.integratedLufs, response.truePeak)
    }

    // MARK: - Plumbing

    private func makeURL(_ path: String, query: [URLQueryItem]) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/\(path)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var request = URLRequest(url: makeURL(path, query: query))
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        return try await execute(request)
    }

    private func post<T: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> T {
        var request = URLRequest(url: makeURL(path, query: []))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await execute(request)
    }

    private func execute<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200..<300:
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw SonicError.invalidResponse
            }
        case 401:
            throw SonicError.unauthorized
        case 404:
            throw SonicError.notFound(request.url?.lastPathComponent ?? "")
        default:
            throw SonicError.serverError(status: response.statusCode)
        }
    }
}
