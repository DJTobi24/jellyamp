import Foundation
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends `PlaybackReporter` events to `/Sessions/Playing*` so Jellyfin tracks
/// play counts, resume positions, and releases transcode jobs.
public final class PlaybackReportingAPI: @unchecked Sendable {
    private let session: JellyfinSession
    private let transport: HTTPTransport
    /// `DirectStream` or `Transcode` — Jellyfin distinguishes them in stats.
    public var playMethod: String

    public init(session: JellyfinSession, transport: HTTPTransport = URLSessionTransport(), playMethod: String = "DirectStream") {
        self.session = session
        self.transport = transport
        self.playMethod = playMethod
    }

    public func send(_ report: PlaybackReport, playSessionID: String) async throws {
        let request = try makeRequest(for: report, playSessionID: playSessionID)
        let (_, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw JellyfinError.serverError(status: response.statusCode)
        }
    }

    func makeRequest(for report: PlaybackReport, playSessionID: String) throws -> URLRequest {
        struct Body: Codable {
            var ItemId: String
            var PositionTicks: Int64
            var IsPaused: Bool
            var PlayMethod: String
            var PlaySessionId: String
            var CanSeek: Bool
        }
        let path: String
        let body: Body
        switch report {
        case .started(let trackID, let ticks):
            path = "Sessions/Playing"
            body = Body(ItemId: trackID, PositionTicks: ticks, IsPaused: false, PlayMethod: playMethod, PlaySessionId: playSessionID, CanSeek: true)
        case .progress(let trackID, let ticks, let isPaused):
            path = "Sessions/Playing/Progress"
            body = Body(ItemId: trackID, PositionTicks: ticks, IsPaused: isPaused, PlayMethod: playMethod, PlaySessionId: playSessionID, CanSeek: true)
        case .stopped(let trackID, let ticks):
            path = "Sessions/Playing/Stopped"
            body = Body(ItemId: trackID, PositionTicks: ticks, IsPaused: false, PlayMethod: playMethod, PlaySessionId: playSessionID, CanSeek: true)
        }
        return session.request(path: path, method: "POST", body: try JSONEncoder().encode(body))
    }
}
