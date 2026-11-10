import Foundation
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The plumbing every Jellyfin REST call shares: request building (query
/// encoding, timeouts), status → `JellyfinError` mapping and tolerant
/// decoding. `MusicLibraryAPI`, `InstantMixAPI` and `LyricsAPI` all go through
/// it so a server quirk is handled once. Behaviour is pinned against a real
/// server by `JellyfinLiveTests`; see `docs/JELLYFIN-API-NOTES.md`.
struct JellyfinClient: Sendable {
    let session: JellyfinSession
    let transport: HTTPTransport

    /// Metadata calls answer in milliseconds on a healthy server; URLSession's
    /// default of 60 s only makes a dead connection look like a hung UI.
    static let requestTimeout: TimeInterval = 30
    /// Image uploads go out over cellular too.
    static let uploadTimeout: TimeInterval = 120
    /// IDs travel comma-joined in the query string. 100 GUIDs are 3.3 kB;
    /// Jellyfin's Kestrel answers 414 somewhere between 6.6 kB and 13 kB, and
    /// reverse proxies in front of it are often stricter (nginx: 4–8 kB).
    static let maxIDsPerRequest = 100

    // MARK: - Requests

    func request(
        path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        timeout: TimeInterval = JellyfinClient.requestTimeout
    ) -> URLRequest {
        var request = session.request(path: path, query: query, method: method, body: body)
        request.url = request.url.map(Self.encodingPlusSigns(in:))
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// `userId=…` for the endpoints that take the user as a query parameter;
    /// empty when signed out (the token alone identifies the user then, an
    /// empty `userId=` would be a 400).
    var userQuery: [URLQueryItem] {
        session.userID.map { [URLQueryItem(name: "userId", value: $0)] } ?? []
    }

    /// `URLComponents` leaves "+" alone because RFC 3986 allows it in a query,
    /// but Jellyfin (ASP.NET) decodes it as a space: searching for "AC+DC"
    /// would look for "AC DC" and a playlist named "A+B" would be created as
    /// "A B".
    static func encodingPlusSigns(in url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = components.percentEncodedQuery, query.contains("+")
        else { return url }
        components.percentEncodedQuery = query.replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? url
    }

    // MARK: - Responses

    /// Sends the request and returns the body of a 2xx answer; anything else
    /// throws the `JellyfinError` for that status (see `JellyfinError.httpStatus`).
    @discardableResult
    func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.send(request)
        if let error = JellyfinError(httpStatus: response.statusCode) {
            throw error
        }
        return data
    }

    func decode<T: Decodable>(_ type: T.Type = T.self, from request: URLRequest) async throws -> T {
        let data = try await send(request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw JellyfinError.invalidResponse
        }
    }

    /// A `{ "Items": [...] }` list endpoint. Adds `fields` and `userId` unless
    /// the caller set them, and skips the total count nobody reads (it costs
    /// the server a second query).
    func items(path: String = "Items", query: [URLQueryItem]) async throws -> [BaseItemDto] {
        var fullQuery = query
        func has(_ name: String) -> Bool { fullQuery.contains { $0.name == name } }
        if !has("fields") {
            fullQuery.append(URLQueryItem(name: "fields", value: defaultFields))
        }
        if !has("userId") {
            fullQuery.append(contentsOf: userQuery)
        }
        if !has("enableTotalRecordCount") {
            fullQuery.append(URLQueryItem(name: "enableTotalRecordCount", value: "false"))
        }
        let response: ItemsResponse = try await decode(from: request(path: path, query: fullQuery))
        return response.Items
    }

    /// Fetches items by ID in URL-length-safe batches, in request order.
    func items(ids: [String], query: [URLQueryItem] = []) async throws -> [BaseItemDto] {
        var result: [BaseItemDto] = []
        for batch in Self.batches(of: ids) {
            result += try await items(query: [URLQueryItem(name: "ids", value: batch.joined(separator: ","))] + query)
        }
        return result
    }

    static func batches(of ids: [String], size: Int = JellyfinClient.maxIDsPerRequest) -> [[String]] {
        stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min($0 + size, ids.count)]) }
    }

    /// Jellyfin prints item IDs as 32 lowercase hex digits but accepts dashed
    /// and uppercase GUIDs; compare them the way the server does.
    static func sameID(_ lhs: String, _ rhs: String) -> Bool {
        func canonical(_ id: String) -> String { id.replacingOccurrences(of: "-", with: "").lowercased() }
        return canonical(lhs) == canonical(rhs)
    }
}

extension JellyfinError {
    /// The error for an HTTP status, nil for 2xx. This is the one mapping all
    /// Jellyfin calls in this package use:
    ///
    /// - 401 → `.unauthorized`: the token is missing, expired or revoked
    ///   (Jellyfin answers 401 for every call then, including stream and
    ///   image URLs that carry `api_key`). Session-expiry handling hooks here.
    /// - 404 → `.notFound`: the item (or route) does not exist.
    /// - anything else → `.serverError(status:)`, e.g. 403 when the user's
    ///   policy forbids the action (deleting items), 400 for a malformed ID,
    ///   414 for an over-long URL, 5xx.
    init?(httpStatus: Int) {
        switch httpStatus {
        case 200..<300: return nil
        case 401: self = .unauthorized
        case 404: self = .notFound
        default: self = .serverError(status: httpStatus)
        }
    }

    /// The HTTP status behind this error; nil for errors that are not an HTTP
    /// answer (`invalidResponse`, `notAuthenticated`).
    public var httpStatus: Int? {
        switch self {
        case .unauthorized: return 401
        case .notFound: return 404
        case .serverError(let status): return status
        case .invalidResponse, .notAuthenticated: return nil
        }
    }
}

/// Decodes a JSON array element by element and drops the elements that do not
/// decode, so one malformed item cannot take a whole page down with it.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                // A failed decode does not advance the container.
                _ = try container.decode(Skipped.self)
            }
        }
        self.elements = elements
    }
}
