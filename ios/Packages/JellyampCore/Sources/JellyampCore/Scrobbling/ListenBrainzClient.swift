import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ListenBrainz scrobbler (https://listenbrainz.readthedocs.io). Token auth,
/// JSON bodies, no request signing. `baseURL` can point at a self-hosted
/// ListenBrainz-compatible server (e.g. Maloja, Koito) instead.
public struct ListenBrainzClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.listenbrainz.org")!
    /// Where users copy their token from.
    public static let tokenSettingsURL = URL(string: "https://listenbrainz.org/settings/")!
    /// `MAX_LISTENS_PER_REQUEST` of the ListenBrainz API.
    public static let maxListensPerRequest = 1000
    /// Reported as `media_player` / `submission_client`.
    public static let clientName = "Jellyamp"

    private let baseURL: URL
    private let token: String
    private let transport: HTTPTransport
    private let clientVersion: String?

    public init(
        token: String,
        baseURL: URL = ListenBrainzClient.defaultBaseURL,
        transport: HTTPTransport = URLSessionTransport(),
        clientVersion: String? = nil
    ) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
        self.clientVersion = clientVersion
    }

    struct SubmissionPayload: Codable {
        struct Listen: Codable {
            struct AdditionalInfo: Codable {
                var mediaPlayer: String
                var submissionClient: String
                var submissionClientVersion: String?
                var durationMs: Int?
                var tracknumber: Int?

                enum CodingKeys: String, CodingKey {
                    case mediaPlayer = "media_player"
                    case submissionClient = "submission_client"
                    case submissionClientVersion = "submission_client_version"
                    case durationMs = "duration_ms"
                    case tracknumber
                }
            }

            struct TrackMetadata: Codable {
                var artistName: String
                var trackName: String
                var releaseName: String?
                var additionalInfo: AdditionalInfo

                enum CodingKeys: String, CodingKey {
                    case artistName = "artist_name"
                    case trackName = "track_name"
                    case releaseName = "release_name"
                    case additionalInfo = "additional_info"
                }
            }

            var listenedAt: Int?
            var trackMetadata: TrackMetadata

            enum CodingKeys: String, CodingKey {
                case listenedAt = "listened_at"
                case trackMetadata = "track_metadata"
            }
        }

        var listenType: String
        var payload: [Listen]

        enum CodingKeys: String, CodingKey {
            case listenType = "listen_type"
            case payload
        }
    }

    /// A track counts as "listened" per ListenBrainz rules (half the track or
    /// 4 minutes, whichever is lower).
    public static func countsAsListen(playedSeconds: TimeInterval, trackDuration: TimeInterval) -> Bool {
        guard trackDuration > 0 else { return false }
        return playedSeconds >= min(trackDuration / 2, 240)
    }

    // MARK: - Submitting

    public func submitListen(track: Track, listenedAt: Date) async throws {
        try await submit(listens: [ScrobbleListen(track: track, startedAt: listenedAt)])
    }

    public func submitNowPlaying(track: Track) async throws {
        try await submitNowPlaying(listen: ScrobbleListen(track: track, startedAt: Date()))
    }

    /// `playing_now`: carries no timestamp (the server rejects one).
    public func submitNowPlaying(listen: ScrobbleListen) async throws {
        let payload = SubmissionPayload(
            listenType: "playing_now",
            payload: [makeListen(listen, includeTimestamp: false)]
        )
        try await submit(payload)
    }

    /// Submits finished listens: one as `single`, several as `import`
    /// (the batch type), split into requests of at most 1000.
    public func submit(listens: [ScrobbleListen]) async throws {
        guard !listens.isEmpty else { return }
        if listens.count == 1 {
            let payload = SubmissionPayload(
                listenType: "single",
                payload: [makeListen(listens[0], includeTimestamp: true)]
            )
            try await submit(payload)
            return
        }
        var start = 0
        while start < listens.count {
            let end = min(start + Self.maxListensPerRequest, listens.count)
            let payload = SubmissionPayload(
                listenType: "import",
                payload: listens[start..<end].map { makeListen($0, includeTimestamp: true) }
            )
            try await submit(payload)
            start = end
        }
    }

    // MARK: - Token

    public func validateToken() async throws -> Bool {
        try await tokenOwner() != nil
    }

    /// The user name the token belongs to, or nil when the server says the
    /// token is not valid. Throws only when the server cannot be reached.
    public func tokenOwner() async throws -> String? {
        struct Response: Codable {
            var valid: Bool
            var userName: String?

            enum CodingKeys: String, CodingKey {
                case valid
                case userName = "user_name"
            }
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("1/validate-token"))
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data),
              decoded.valid else {
            return nil
        }
        // Older / third-party servers may omit the name; the token is still good.
        return decoded.userName ?? ""
    }

    // MARK: - Internals

    private func makeListen(_ listen: ScrobbleListen, includeTimestamp: Bool) -> SubmissionPayload.Listen {
        SubmissionPayload.Listen(
            listenedAt: includeTimestamp ? listen.timestamp : nil,
            trackMetadata: .init(
                artistName: listen.artist,
                trackName: listen.title,
                releaseName: listen.album,
                additionalInfo: .init(
                    mediaPlayer: Self.clientName,
                    submissionClient: Self.clientName,
                    submissionClientVersion: clientVersion,
                    durationMs: listen.duration.map { Int(($0 * 1000).rounded()) },
                    tracknumber: listen.trackNumber
                )
            )
        )
    }

    private func submit(_ payload: SubmissionPayload) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("1/submit-listens"))
        request.httpMethod = "POST"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        let (data, response) = try await transport.send(request)
        let status = response.statusCode
        if (200..<300).contains(status) { return }
        switch status {
        case 401:
            throw ScrobbleError.unauthorized
        case 429:
            throw ScrobbleError.rateLimited(retryAfter: ListenBrainzRateLimit(response: response).resetIn)
        case 400, 413:
            throw ScrobbleError.rejected(status: status, message: Self.errorMessage(in: data) ?? "The listen was not accepted.")
        default:
            throw ScrobbleError.serverError(status: status)
        }
    }

    /// ListenBrainz errors look like `{"code": 400, "error": "…"}`.
    private static func errorMessage(in data: Data) -> String? {
        struct ErrorBody: Codable {
            var error: String?
        }
        return (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
    }
}

/// The `X-RateLimit-*` headers ListenBrainz sends with every response.
public struct ListenBrainzRateLimit: Equatable, Sendable {
    /// Requests left in the current window.
    public var remaining: Int?
    /// Seconds until the window resets — how long to wait after a 429.
    public var resetIn: TimeInterval?

    public init(remaining: Int? = nil, resetIn: TimeInterval? = nil) {
        self.remaining = remaining
        self.resetIn = resetIn
    }

    public init(response: HTTPURLResponse) {
        // Header names are case-insensitive and HTTP/2 lower-cases them, so
        // do not rely on a particular spelling surviving.
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        remaining = headers["x-ratelimit-remaining"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        resetIn = headers["x-ratelimit-reset-in"].flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
    }
}

public enum ScrobbleError: Error, Equatable {
    case serverError(status: Int)
    /// 401: the user token is wrong or was reset.
    case unauthorized
    /// 429: too many requests; wait `retryAfter` seconds when known.
    case rateLimited(retryAfter: TimeInterval?)
    /// 400 / 413: the payload itself was refused; retrying cannot help.
    case rejected(status: Int, message: String)
}

/// Adapts `ListenBrainzClient` to the scrobble engine.
public struct ListenBrainzScrobbleTarget: ScrobbleTarget {
    public let service = ScrobbleServiceID.listenBrainz
    public let maxBatchSize = ListenBrainzClient.maxListensPerRequest
    private let client: ListenBrainzClient

    public init(client: ListenBrainzClient) {
        self.client = client
    }

    public func sendNowPlaying(_ listen: ScrobbleListen) async throws {
        try await mapErrors { try await client.submitNowPlaying(listen: listen) }
    }

    public func submit(_ listens: [ScrobbleListen]) async throws {
        try await mapErrors { try await client.submit(listens: listens) }
    }

    private func mapErrors(_ operation: () async throws -> Void) async throws {
        do {
            try await operation()
        } catch let error as ScrobbleError {
            switch error {
            case .unauthorized:
                throw ScrobbleDeliveryError.reauthenticate(message: CoreStrings.current.listenBrainzTokenRejected)
            case .rateLimited(let retryAfter):
                throw ScrobbleDeliveryError.retryLater(after: retryAfter, message: CoreStrings.current.listenBrainzRateLimited)
            case .rejected(_, let message):
                throw ScrobbleDeliveryError.rejected(message: message)
            case .serverError(let status):
                if status >= 500 {
                    throw ScrobbleDeliveryError.retryLater(after: nil, message: CoreStrings.current.listenBrainzUnavailable(status))
                }
                throw ScrobbleDeliveryError.rejected(message: CoreStrings.current.listenBrainzRefused(status))
            }
        } catch {
            throw ScrobbleDeliveryError.offline
        }
    }
}
