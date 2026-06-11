import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// ListenBrainz scrobbler (https://listenbrainz.readthedocs.io). Chosen as
/// the first scrobble target because its token auth needs no signing;
/// Last.fm (MD5-signed) follows in Phase 4.
public struct ListenBrainzClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.listenbrainz.org")!

    private let baseURL: URL
    private let token: String
    private let transport: HTTPTransport

    public init(token: String, baseURL: URL = ListenBrainzClient.defaultBaseURL, transport: HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
    }

    struct SubmissionPayload: Codable {
        struct Listen: Codable {
            struct TrackMetadata: Codable {
                var artist_name: String
                var track_name: String
                var release_name: String?
            }
            var listened_at: Int?
            var track_metadata: TrackMetadata
        }
        var listen_type: String
        var payload: [Listen]
    }

    /// A track counts as "listened" per ListenBrainz rules (half the track or
    /// 4 minutes, whichever is lower).
    public static func countsAsListen(playedSeconds: TimeInterval, trackDuration: TimeInterval) -> Bool {
        guard trackDuration > 0 else { return false }
        return playedSeconds >= min(trackDuration / 2, 240)
    }

    public func submitListen(track: Track, listenedAt: Date) async throws {
        let payload = SubmissionPayload(
            listen_type: "single",
            payload: [makeListen(track: track, listenedAt: listenedAt)]
        )
        try await submit(payload)
    }

    public func submitNowPlaying(track: Track) async throws {
        let payload = SubmissionPayload(
            listen_type: "playing_now",
            payload: [makeListen(track: track, listenedAt: nil)]
        )
        try await submit(payload)
    }

    public func validateToken() async throws -> Bool {
        struct Response: Codable {
            var valid: Bool
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("1/validate-token"))
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200, let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            return false
        }
        return decoded.valid
    }

    private func makeListen(track: Track, listenedAt: Date?) -> SubmissionPayload.Listen {
        SubmissionPayload.Listen(
            listened_at: listenedAt.map { Int($0.timeIntervalSince1970) },
            track_metadata: .init(
                artist_name: track.artistName,
                track_name: track.title,
                release_name: track.albumName
            )
        )
    }

    private func submit(_ payload: SubmissionPayload) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("1/submit-listens"))
        request.httpMethod = "POST"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        let (_, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ScrobbleError.serverError(status: response.statusCode)
        }
    }
}

public enum ScrobbleError: Error, Equatable {
    case serverError(status: Int)
}
