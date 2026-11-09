import Foundation
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `/Audio/{id}/Lyrics` (Jellyfin 10.9+): synced or plain lyrics.
public final class LyricsAPI: @unchecked Sendable {
    private let client: JellyfinClient

    public init(session: JellyfinSession, transport: HTTPTransport = URLSessionTransport()) {
        self.client = JellyfinClient(session: session, transport: transport)
    }

    /// `LyricDto`. Only `Lyrics` is read; a line that does not decode is
    /// dropped rather than costing the whole song its lyrics.
    struct LyricsDto: Decodable {
        struct Line: Decodable {
            var Text: String?
            /// Ticks (100 ns); nil for unsynced lyrics.
            var Start: Int64?
        }
        var Lyrics: LossyArray<Line>?
    }

    /// Returns nil when the track has no lyrics: Jellyfin answers 404 both for
    /// "no lyrics" and for an unknown item.
    public func lyrics(forTrack trackID: String) async throws -> LyricsTimeline? {
        let dto: LyricsDto
        do {
            dto = try await client.decode(from: client.request(path: "Audio/\(trackID)/Lyrics"))
        } catch JellyfinError.notFound {
            return nil
        }
        let lines = (dto.Lyrics?.elements ?? []).map {
            LyricLine(start: $0.Start.map { Double($0) / 10_000_000 }, text: $0.Text ?? "")
        }
        // A lyrics file with nothing in it is "no lyrics" to the UI.
        return lines.isEmpty ? nil : LyricsTimeline(lines: lines)
    }
}
