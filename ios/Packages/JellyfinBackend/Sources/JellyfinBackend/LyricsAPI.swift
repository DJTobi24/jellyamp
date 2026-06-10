import Foundation
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `/Audio/{id}/Lyrics` (Jellyfin 10.9+): synced or plain lyrics.
public final class LyricsAPI: @unchecked Sendable {
    private let session: JellyfinSession
    private let transport: HTTPTransport

    public init(session: JellyfinSession, transport: HTTPTransport = URLSessionTransport()) {
        self.session = session
        self.transport = transport
    }

    struct LyricsDto: Codable {
        struct Line: Codable {
            var Text: String
            /// Ticks (100 ns); nil for unsynced lyrics.
            var Start: Int64?
        }
        var Lyrics: [Line]
    }

    /// Returns nil when the track has no lyrics (404).
    public func lyrics(forTrack trackID: String) async throws -> LyricsTimeline? {
        let request = session.request(path: "Audio/\(trackID)/Lyrics")
        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200:
            guard let dto = try? JSONDecoder().decode(LyricsDto.self, from: data) else {
                throw JellyfinError.invalidResponse
            }
            let lines = dto.Lyrics.map {
                LyricLine(start: $0.Start.map { Double($0) / 10_000_000 }, text: $0.Text)
            }
            return LyricsTimeline(lines: lines)
        case 404:
            return nil
        default:
            throw JellyfinError.serverError(status: response.statusCode)
        }
    }
}
