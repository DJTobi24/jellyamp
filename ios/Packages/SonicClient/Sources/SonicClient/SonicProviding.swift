import Foundation
import JellyampCore

/// Sonic features the app can offer. Mirrors the `capabilities` array of
/// `GET /api/v1/info` (docs/SONIC-API.md).
public enum SonicCapability: String, Codable, CaseIterable, Sendable {
    case similar
    case adventure
    case mixes
    case stations
    case loudness
}

public struct SonicCapabilities: Equatable, Sendable {
    public var capabilities: Set<SonicCapability>
    /// nil when the Jellyfin fallback is active (no analysis progress to show).
    public var analysisProgress: AnalysisProgress?

    public struct AnalysisProgress: Equatable, Sendable {
        public var tracksAnalyzed: Int
        public var tracksTotal: Int

        public init(tracksAnalyzed: Int, tracksTotal: Int) {
            self.tracksAnalyzed = tracksAnalyzed
            self.tracksTotal = tracksTotal
        }
    }

    public init(capabilities: Set<SonicCapability>, analysisProgress: AnalysisProgress? = nil) {
        self.capabilities = capabilities
        self.analysisProgress = analysisProgress
    }

    public func supports(_ capability: SonicCapability) -> Bool {
        capabilities.contains(capability)
    }
}

public enum StationType: String, Codable, Sendable {
    case genre
    case mood
    case decade
    case style
}

/// A similarity result; IDs are Jellyfin item IDs, resolved through the
/// library layer for display.
public struct SimilarItem: Codable, Equatable, Sendable {
    public var itemID: String
    public var distance: Double

    public init(itemID: String, distance: Double) {
        self.itemID = itemID
        self.distance = distance
    }
}

/// The seam between the app and "smart" features. Implemented by
/// `SonicAPIClient` (jellyamp-server) and `JellyfinFallbackSonicProvider`.
public protocol SonicProviding: Sendable {
    var capabilities: SonicCapabilities { get async }

    func similarTracks(to itemID: String, limit: Int) async throws -> [SimilarItem]
    func similarArtists(to artistID: String, limit: Int) async throws -> [SimilarItem]
    func similarAlbums(to albumID: String, limit: Int) async throws -> [SimilarItem]
    /// Sonic Adventure: a sonically interpolated path of track IDs from one
    /// track to another, endpoints included.
    func adventure(from: String, to: String, steps: Int) async throws -> [String]
    func mixes(forUser userID: String) async throws -> [MixDescriptor]
    func station(type: StationType, seed: String, count: Int) async throws -> [String]
    /// Measured loudness for tracks without `NormalizationGain` tags.
    func loudness(forTrack itemID: String) async throws -> (integratedLufs: Double, truePeak: Double)
}

public enum SonicError: Error, Equatable {
    case unsupported(SonicCapability)
    case unauthorized
    case notFound(String)
    case serverError(status: Int)
    case invalidResponse
}
