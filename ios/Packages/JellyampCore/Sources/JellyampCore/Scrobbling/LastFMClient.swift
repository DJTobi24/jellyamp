import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The per-app Last.fm API account (https://www.last.fm/api/account/create).
/// The shared secret necessarily ships inside the app — that is how every
/// Last.fm desktop and mobile client works; it identifies the app, it does
/// not grant access to any user account.
public struct LastFMCredentials: Equatable, Sendable {
    public var apiKey: String
    public var sharedSecret: String

    public init(apiKey: String, sharedSecret: String) {
        self.apiKey = apiKey
        self.sharedSecret = sharedSecret
    }

    /// Builds credentials from raw configuration values (Info.plist), or
    /// nil when either is missing or still an unexpanded `$(BUILD_SETTING)`.
    public init?(configuredAPIKey: String?, configuredSecret: String?) {
        guard let key = Self.usable(configuredAPIKey), let secret = Self.usable(configuredSecret) else { return nil }
        self.init(apiKey: key, sharedSecret: secret)
    }

    private static func usable(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}

/// A user's authorization of this app; `key` is the secret to keep (Keychain).
/// Last.fm session keys do not expire unless the user revokes the app.
public struct LastFMSession: Codable, Equatable, Sendable {
    public var username: String
    public var key: String

    public init(username: String, key: String) {
        self.username = username
        self.key = key
    }
}

public struct LastFMUser: Equatable, Sendable {
    public var name: String
    public var playCount: Int?
    public var profileURL: URL?
}

public struct LastFMScrobbleResult: Equatable, Sendable {
    /// Scrobbles Last.fm stored.
    public var accepted: Int
    /// Scrobbles Last.fm filtered out (too old, too new, artist blocked, …).
    /// They will never be accepted, so they are not retried.
    public var ignored: Int
}

public enum LastFMError: Error, Equatable, Sendable {
    /// An error reported by the API (`{"error": 9, "message": "…"}`).
    case api(code: Int, message: String)
    /// A non-2xx answer without a Last.fm error body.
    case http(status: Int)
    /// A 2xx answer that is not the documented shape.
    case malformedResponse
    /// A call that needs a session key was made without one.
    case notAuthenticated

    public enum Kind: Equatable, Sendable {
        /// 9: the session key was revoked — forget it and ask to reconnect.
        case invalidSession
        /// 8, 11, 16, 29 and server-side HTTP failures: try again later.
        case retryLater
        /// 14: the user has not approved the token (yet).
        case authorizationPending
        /// 4, 15: the token is unknown or older than 60 minutes; start over.
        case invalidToken
        /// 10, 26: the app's API key is wrong or suspended (developer problem).
        case invalidAPIKey
        case other
    }

    public var kind: Kind {
        switch self {
        case .api(let code, _):
            switch code {
            case 9: return .invalidSession
            case 8, 11, 16, 29: return .retryLater
            case 14: return .authorizationPending
            case 4, 15: return .invalidToken
            case 10, 26: return .invalidAPIKey
            default: return .other
            }
        case .http(let status):
            return status >= 500 || status == 429 ? .retryLater : .other
        case .malformedResponse:
            return .other
        case .notAuthenticated:
            return .invalidSession
        }
    }
}

/// Last.fm API 2.0 client (https://www.last.fm/api): the token-based auth
/// flow for native apps, now-playing and scrobbling.
///
/// Every call is a form-encoded POST to the API root with `format=json`.
/// Calls are signed: `api_sig` is the MD5 of all parameters except `format`
/// and `callback`, sorted by name and concatenated as `<name><value>`,
/// followed by the shared secret.
public struct LastFMClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    public static let authorizationBaseURL = URL(string: "https://www.last.fm/api/auth/")!
    /// `track.scrobble` accepts at most 50 scrobbles per request.
    public static let maxScrobblesPerRequest = 50

    private let credentials: LastFMCredentials
    private let sessionKey: String?
    private let baseURL: URL
    private let transport: HTTPTransport

    public init(
        credentials: LastFMCredentials,
        sessionKey: String? = nil,
        baseURL: URL = LastFMClient.defaultBaseURL,
        transport: HTTPTransport = URLSessionTransport()
    ) {
        self.credentials = credentials
        self.sessionKey = sessionKey
        self.baseURL = baseURL
        self.transport = transport
    }

    // MARK: - Authentication

    /// Step 1: fetch an unauthorized request token (valid for 60 minutes).
    public func getToken() async throws -> String {
        let json = try await call(method: "auth.getToken", parameters: [:], authenticated: false)
        guard let token = json["token"] as? String, !token.isEmpty else { throw LastFMError.malformedResponse }
        return token
    }

    /// Step 2: the page where the user approves the token. Open it in a
    /// browser; when the user is done, call `getSession(token:)`.
    public func authorizationURL(token: String) -> URL {
        var components = URLComponents(url: Self.authorizationBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: credentials.apiKey),
            URLQueryItem(name: "token", value: token),
        ]
        return components.url!
    }

    /// Step 3: trade the approved token for a session. Fails with error 14
    /// (`.authorizationPending`) while the user has not approved it.
    public func getSession(token: String) async throws -> LastFMSession {
        let json = try await call(method: "auth.getSession", parameters: ["token": token], authenticated: false)
        guard let session = json["session"] as? [String: Any],
              let name = session["name"] as? String,
              let key = session["key"] as? String, !key.isEmpty else {
            throw LastFMError.malformedResponse
        }
        return LastFMSession(username: name, key: key)
    }

    /// The signed-in user (`user.getInfo` without a `user` parameter).
    public func getUserInfo() async throws -> LastFMUser {
        let json = try await call(method: "user.getInfo", parameters: [:], authenticated: true)
        guard let user = json["user"] as? [String: Any], let name = user["name"] as? String else {
            throw LastFMError.malformedResponse
        }
        return LastFMUser(
            name: name,
            playCount: Self.int(user["playcount"]),
            profileURL: (user["url"] as? String).flatMap { URL(string: $0) }
        )
    }

    // MARK: - Scrobbling

    public func updateNowPlaying(_ listen: ScrobbleListen) async throws {
        var parameters: [String: String] = [
            "artist": listen.artist,
            "track": listen.title,
        ]
        parameters["album"] = listen.album
        parameters["albumArtist"] = listen.albumArtist
        parameters["trackNumber"] = listen.trackNumber.map(String.init)
        parameters["duration"] = Self.wholeSeconds(listen.duration)
        _ = try await call(method: "track.updateNowPlaying", parameters: parameters, authenticated: true)
    }

    /// Scrobbles the listens, 50 per request, using the array notation
    /// (`artist[0]`, `track[0]`, `timestamp[0]`, …).
    @discardableResult
    public func scrobble(_ listens: [ScrobbleListen]) async throws -> LastFMScrobbleResult {
        var total = LastFMScrobbleResult(accepted: 0, ignored: 0)
        var start = 0
        while start < listens.count {
            let end = min(start + Self.maxScrobblesPerRequest, listens.count)
            let result = try await scrobbleBatch(Array(listens[start..<end]))
            total.accepted += result.accepted
            total.ignored += result.ignored
            start = end
        }
        return total
    }

    private func scrobbleBatch(_ listens: [ScrobbleListen]) async throws -> LastFMScrobbleResult {
        var parameters: [String: String] = [:]
        for (index, listen) in listens.enumerated() {
            parameters["artist[\(index)]"] = listen.artist
            parameters["track[\(index)]"] = listen.title
            parameters["timestamp[\(index)]"] = String(listen.timestamp)
            parameters["album[\(index)]"] = listen.album
            parameters["albumArtist[\(index)]"] = listen.albumArtist
            parameters["trackNumber[\(index)]"] = listen.trackNumber.map(String.init)
            parameters["duration[\(index)]"] = Self.wholeSeconds(listen.duration)
        }
        let json = try await call(method: "track.scrobble", parameters: parameters, authenticated: true)
        // {"scrobbles": {"@attr": {"accepted": 1, "ignored": 0}, "scrobble": …}}
        guard let scrobbles = json["scrobbles"] as? [String: Any],
              let attributes = scrobbles["@attr"] as? [String: Any],
              let accepted = Self.int(attributes["accepted"]) else {
            throw LastFMError.malformedResponse
        }
        return LastFMScrobbleResult(accepted: accepted, ignored: Self.int(attributes["ignored"]) ?? 0)
    }

    // MARK: - Request building (internal for tests)

    /// `api_sig` for a set of parameters. `format` and `callback` are not
    /// part of the signature. Names are ordered by their UTF-8 bytes, which
    /// for the ASCII names Last.fm uses is the "alphabetical" order of the
    /// docs — note that this puts `artist[10]` before `artist[1]`.
    static func signature(parameters: [String: String], secret: String) -> String {
        var base = ""
        for name in sortedNames(parameters) where name != "format" && name != "callback" {
            base += name
            base += parameters[name] ?? ""
        }
        base += secret
        return MD5.hexDigest(of: base)
    }

    /// `application/x-www-form-urlencoded` body with a stable field order.
    static func formEncode(_ parameters: [String: String]) -> String {
        sortedNames(parameters)
            .map { "\(percentEncode($0))=\(percentEncode(parameters[$0] ?? ""))" }
            .joined(separator: "&")
    }

    private static func sortedNames(_ parameters: [String: String]) -> [String] {
        parameters.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    /// RFC 3986 unreserved characters stay; everything else — including
    /// `&`, `=`, `+` and spaces — is percent-encoded as UTF-8.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func wholeSeconds(_ duration: TimeInterval?) -> String? {
        guard let duration, duration >= 1 else { return nil }
        return String(Int(duration.rounded()))
    }

    /// Last.fm's JSON is converted from XML and is loose about numbers:
    /// the same field may arrive as `1` or `"1"`.
    private static func int(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let text = value as? String { return Int(text) }
        if let number = value as? Double { return Int(number) }
        return nil
    }

    private func call(method: String, parameters: [String: String], authenticated: Bool) async throws -> [String: Any] {
        var all = parameters
        all["method"] = method
        all["api_key"] = credentials.apiKey
        if authenticated {
            guard let sessionKey, !sessionKey.isEmpty else { throw LastFMError.notAuthenticated }
            all["sk"] = sessionKey
        }
        all["api_sig"] = Self.signature(parameters: all, secret: credentials.sharedSecret)
        all["format"] = "json"

        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncode(all).utf8)

        let (data, response) = try await transport.send(request)
        let object = try? JSONSerialization.jsonObject(with: data)
        let json = object as? [String: Any]
        // Errors come with assorted HTTP statuses (400, 403, 500, sometimes
        // 200), so the body decides first.
        if let json, let code = Self.int(json["error"]) {
            throw LastFMError.api(code: code, message: (json["message"] as? String) ?? "Last.fm error \(code)")
        }
        guard (200..<300).contains(response.statusCode) else {
            throw LastFMError.http(status: response.statusCode)
        }
        guard let json else { throw LastFMError.malformedResponse }
        return json
    }
}

/// Adapts `LastFMClient` to the scrobble engine.
public struct LastFMScrobbleTarget: ScrobbleTarget {
    public let service = ScrobbleServiceID.lastFM
    public let maxBatchSize = LastFMClient.maxScrobblesPerRequest
    private let client: LastFMClient

    public init(client: LastFMClient) {
        self.client = client
    }

    public func sendNowPlaying(_ listen: ScrobbleListen) async throws {
        try await mapErrors { try await client.updateNowPlaying(listen) }
    }

    public func submit(_ listens: [ScrobbleListen]) async throws {
        try await mapErrors { _ = try await client.scrobble(listens) }
    }

    private func mapErrors(_ operation: () async throws -> Void) async throws {
        do {
            try await operation()
        } catch let error as LastFMError {
            switch error.kind {
            case .invalidSession:
                throw ScrobbleDeliveryError.reauthenticate(message: "Last.fm no longer accepts this session. Connect again.")
            case .retryLater:
                // 29 is the rate limit; back off longer than for a blip.
                var delay: TimeInterval?
                if case .api(let code, _) = error, code == 29 { delay = 300 }
                throw ScrobbleDeliveryError.retryLater(after: delay, message: Self.describe(error))
            case .invalidAPIKey:
                // Nothing the user or a retry can fix quickly; keep the
                // listens and look again in an hour.
                throw ScrobbleDeliveryError.retryLater(after: 3600, message: Self.describe(error))
            case .authorizationPending, .invalidToken, .other:
                throw ScrobbleDeliveryError.rejected(message: Self.describe(error))
            }
        } catch {
            throw ScrobbleDeliveryError.offline
        }
    }

    private static func describe(_ error: LastFMError) -> String {
        switch error {
        case .api(let code, let message): return "Last.fm: \(message) (error \(code))"
        case .http(let status): return "Last.fm is unavailable (HTTP \(status))."
        case .malformedResponse: return "Last.fm sent an unexpected response."
        case .notAuthenticated: return "Not connected to Last.fm."
        }
    }
}
