import Foundation
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Wire-format DTOs matching docs/SONIC-API.md. Internal: the app sees only
/// `SonicProviding` types. Fields added in API 1.1 are optional so 1.0
/// servers still decode; unknown fields from newer servers are ignored.
struct InfoResponse: Codable {
    struct Analysis: Codable {
        var backend: String
        var version: String
    }

    var version: String
    var jellyfinServerId: String
    var tracksTotal: Int
    var tracksAnalyzed: Int
    var capabilities: [String]
    var analysis: Analysis?
    var scan: ScanInfo?
}

struct ScanInfo: Codable {
    var state: String
    var startedAt: String?
    var finishedAt: String?
    var tracksPending: Int?
    var tracksFailed: Int?
    var lastError: String?
}

struct ScanResponse: Codable {
    var started: Bool
    var scan: ScanInfo
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

struct SageRequest: Codable {
    var prompt: String
    var count: Int
}

struct SageResponse: Codable {
    var title: String
    var description: String
    var itemIds: [String]
}

/// FastAPI error body: `detail` is a string, or (for 422) a list of
/// validation errors each carrying a `msg`.
struct ErrorResponse: Decodable {
    struct ValidationIssue: Decodable {
        var msg: String?
    }

    var message: String

    private enum CodingKeys: String, CodingKey {
        case detail
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .detail) {
            message = text
        } else if let issues = try? container.decode([ValidationIssue].self, forKey: .detail) {
            message = issues.compactMap(\.msg).joined(separator: "; ")
        } else {
            message = ""
        }
    }
}

extension SonicScanStatus {
    init(_ info: ScanInfo) {
        self.init(
            // A state this build does not know is, for the UI, "not scanning".
            state: State(rawValue: info.state) ?? .idle,
            startedAt: info.startedAt.flatMap(SonicScanStatus.parseTimestamp),
            finishedAt: info.finishedAt.flatMap(SonicScanStatus.parseTimestamp),
            tracksPending: info.tracksPending ?? 0,
            tracksFailed: info.tracksFailed ?? 0,
            lastError: info.lastError
        )
    }

    static func parseTimestamp(_ text: String) -> Date? {
        // Created per call: ISO8601DateFormatter is not Sendable.
        ISO8601DateFormatter().date(from: text)
    }
}

extension SonicCapabilities {
    init(_ info: InfoResponse) {
        self.init(
            capabilities: Set(info.capabilities.compactMap(SonicCapability.init(rawValue:))),
            analysisProgress: .init(tracksAnalyzed: info.tracksAnalyzed, tracksTotal: info.tracksTotal),
            analysisBackend: info.analysis.map { SonicAnalysisBackend(name: $0.backend, version: $0.version) },
            scan: info.scan.map(SonicScanStatus.init)
        )
    }
}

/// Everything `GET /api/v1/info` reports about a jellyamp-server.
public struct SonicServerInfo: Equatable, Sendable {
    /// Contract version, `major.minor` (the app requires major 1).
    public var version: String
    /// The Jellyfin server this sonic server analyzes; empty while it has
    /// never reached Jellyfin. Compare with the signed-in server's ID to
    /// detect a sonic server that belongs to a different library.
    public var jellyfinServerID: String
    public var capabilities: SonicCapabilities

    public init(version: String, jellyfinServerID: String, capabilities: SonicCapabilities) {
        self.version = version
        self.jellyfinServerID = jellyfinServerID
        self.capabilities = capabilities
    }
}

/// REST client for jellyamp-server (docs/SONIC-API.md).
public final class SonicAPIClient: SonicProviding, @unchecked Sendable {
    /// Sonic Sage waits for a language model; the default 60 s is too tight.
    static let sageTimeout: TimeInterval = 120

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
            return SonicCapabilities(info)
        }
    }

    func fetchInfo() async throws -> InfoResponse {
        try await get("info")
    }

    /// Version, paired Jellyfin server, capabilities, analysis and scan
    /// progress. Unlike `capabilities` this throws when the server cannot be
    /// reached, so a settings screen can tell "offline" from "nothing analyzed".
    public func serverInfo() async throws -> SonicServerInfo {
        let info = try await fetchInfo()
        return SonicServerInfo(
            version: info.version,
            jellyfinServerID: info.jellyfinServerId,
            capabilities: SonicCapabilities(info)
        )
    }

    public func similarTracks(to itemID: String, limit: Int) async throws -> [SimilarItem] {
        try await similar(kind: "tracks", id: itemID, limit: limit)
    }

    public func similarTracks(to itemID: String, limit: Int, excludingSameAlbum: Bool) async throws -> [SimilarItem] {
        try await similar(kind: "tracks", id: itemID, limit: limit, excludingSameAlbum: excludingSameAlbum)
    }

    public func similarArtists(to artistID: String, limit: Int) async throws -> [SimilarItem] {
        try await similar(kind: "artists", id: artistID, limit: limit)
    }

    public func similarAlbums(to albumID: String, limit: Int) async throws -> [SimilarItem] {
        try await similar(kind: "albums", id: albumID, limit: limit)
    }

    private func similar(kind: String, id: String, limit: Int, excludingSameAlbum: Bool = false) async throws -> [SimilarItem] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if excludingSameAlbum {
            query.append(URLQueryItem(name: "excludeSameAlbum", value: "true"))
        }
        let response: SimilarResponse = try await get("similar/\(kind)/\(id)", query: query)
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

    public func sagePlaylist(prompt: String, count: Int) async throws -> SagePlaylist {
        // Errors pass through with the server's explanation: `.notFound` when
        // the request matches nothing in the library, `.unavailable` when Sage
        // is switched off, `.upstreamFailure` when the language model failed.
        let body = SageRequest(prompt: prompt, count: count)
        let response: SageResponse = try await post("sage", body: body, timeout: Self.sageTimeout)
        return SagePlaylist(title: response.title, description: response.description, itemIDs: response.itemIds)
    }

    public func startScan(retryFailed: Bool) async throws -> SonicScanStatus {
        let query = retryFailed ? [URLQueryItem(name: "retryFailed", value: "true")] : []
        var request = URLRequest(url: makeURL("scan", query: query))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        let response: ScanResponse = try await execute(request)
        return SonicScanStatus(response.scan)
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

    private func post<T: Decodable, Body: Encodable>(_ path: String, body: Body, timeout: TimeInterval? = nil) async throws -> T {
        var request = URLRequest(url: makeURL(path, query: []))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        if let timeout { request.timeoutInterval = timeout }
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
        case 409:
            throw SonicError.unavailable(detail(in: data))
        case 422:
            throw SonicError.invalidRequest(detail(in: data))
        case 502:
            throw SonicError.upstreamFailure(detail(in: data))
        default:
            throw SonicError.serverError(status: response.statusCode)
        }
    }

    private func detail(in data: Data) -> String {
        (try? decoder.decode(ErrorResponse.self, from: data))?.message ?? ""
    }
}
