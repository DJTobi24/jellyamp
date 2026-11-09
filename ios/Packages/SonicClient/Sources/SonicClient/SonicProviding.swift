import Foundation
import JellyampCore

/// Sonic features the app can offer. Mirrors the `capabilities` array of
/// `GET /api/v1/info` (docs/SONIC-API.md). Capability strings this build does
/// not know (from a newer server) are ignored when decoding.
public enum SonicCapability: String, Codable, CaseIterable, Sendable {
    case similar
    case adventure
    case mixes
    case stations
    case loudness
    /// Sonic Sage: playlists from a text prompt (API 1.1; needs an LLM key on
    /// the server).
    case sage
}

/// Which analysis backend produced the server's embeddings (API 1.1).
public struct SonicAnalysisBackend: Equatable, Sendable {
    /// `"dsp"` (built-in) or `"musicnn"` (Essentia).
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

/// Progress of the server's library scan (API 1.1, `info.scan`).
public struct SonicScanStatus: Equatable, Sendable {
    public enum State: String, Sendable {
        case idle
        case scanning
    }

    public var state: State
    /// Start of the running or most recent scan; nil before the first one.
    public var startedAt: Date?
    /// nil while a scan is running or before the first one.
    public var finishedAt: Date?
    /// Tracks the running scan still has to analyze (0 when idle).
    public var tracksPending: Int
    /// Tracks the server gave up on after repeated failures.
    public var tracksFailed: Int
    /// Why the most recent scan ended early, e.g. "Jellyfin unreachable: …".
    public var lastError: String?

    public init(
        state: State,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        tracksPending: Int = 0,
        tracksFailed: Int = 0,
        lastError: String? = nil
    ) {
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.tracksPending = tracksPending
        self.tracksFailed = tracksFailed
        self.lastError = lastError
    }

    public var isScanning: Bool { state == .scanning }
}

public struct SonicCapabilities: Equatable, Sendable {
    public var capabilities: Set<SonicCapability>
    /// nil when the Jellyfin fallback is active (no analysis progress to show).
    public var analysisProgress: AnalysisProgress?
    /// nil for the Jellyfin fallback, pre-1.1 servers, and servers that
    /// cannot analyze.
    public var analysisBackend: SonicAnalysisBackend?
    /// nil for the Jellyfin fallback and pre-1.1 servers.
    public var scan: SonicScanStatus?

    public struct AnalysisProgress: Equatable, Sendable {
        public var tracksAnalyzed: Int
        public var tracksTotal: Int

        public init(tracksAnalyzed: Int, tracksTotal: Int) {
            self.tracksAnalyzed = tracksAnalyzed
            self.tracksTotal = tracksTotal
        }

        /// 0…1; 0 for an empty or not yet scanned library.
        public var fraction: Double {
            guard tracksTotal > 0 else { return 0 }
            return min(max(Double(tracksAnalyzed) / Double(tracksTotal), 0), 1)
        }

        public var isComplete: Bool {
            tracksTotal > 0 && tracksAnalyzed >= tracksTotal
        }
    }

    public init(
        capabilities: Set<SonicCapability>,
        analysisProgress: AnalysisProgress? = nil,
        analysisBackend: SonicAnalysisBackend? = nil,
        scan: SonicScanStatus? = nil
    ) {
        self.capabilities = capabilities
        self.analysisProgress = analysisProgress
        self.analysisBackend = analysisBackend
        self.scan = scan
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

/// A Sonic Sage result: a titled, sonically ordered list of track IDs.
public struct SagePlaylist: Codable, Equatable, Sendable {
    public var title: String
    public var description: String
    public var itemIDs: [String]

    public init(title: String, description: String, itemIDs: [String]) {
        self.title = title
        self.description = description
        self.itemIDs = itemIDs
    }
}

/// The seam between the app and "smart" features. Implemented by
/// `SonicAPIClient` (jellyamp-server) and `JellyfinFallbackSonicProvider`.
///
/// Requirements added after 1.0 have default implementations (below) so
/// existing conformers keep compiling; they throw unless overridden.
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

    /// Similar tracks, optionally skipping the seed's own album (useful for
    /// "more like this" below an album's track list).
    func similarTracks(to itemID: String, limit: Int, excludingSameAlbum: Bool) async throws -> [SimilarItem]
    /// Sonic Sage: a playlist for a natural-language request. Requires
    /// `.sage`; can take several seconds. Throws `.notFound` when nothing in
    /// the library matches, `.unavailable` when Sage is switched off on the
    /// server and `.upstreamFailure` when its language model failed.
    func sagePlaylist(prompt: String, count: Int) async throws -> SagePlaylist
    /// Asks the server to scan the library now. Returns the scan status;
    /// poll `capabilities` for progress.
    func startScan(retryFailed: Bool) async throws -> SonicScanStatus
}

public extension SonicProviding {
    func similarTracks(to itemID: String, limit: Int, excludingSameAlbum: Bool) async throws -> [SimilarItem] {
        // Providers without server-side filtering return the unfiltered list;
        // callers that must exclude the album filter by album themselves.
        try await similarTracks(to: itemID, limit: limit)
    }

    func sagePlaylist(prompt: String, count: Int) async throws -> SagePlaylist {
        throw SonicError.unsupported(.sage)
    }

    func startScan(retryFailed: Bool) async throws -> SonicScanStatus {
        throw SonicError.unavailable("This sonic provider has no library scan.")
    }
}

public enum SonicError: Error, Equatable {
    case unsupported(SonicCapability)
    case unauthorized
    case notFound(String)
    case serverError(status: Int)
    case invalidResponse
    /// HTTP 409: the feature exists but is switched off or not ready on this
    /// server; the associated value is the server's explanation.
    case unavailable(String)
    /// HTTP 422: the server rejected a parameter (e.g. an out-of-range count).
    case invalidRequest(String)
    /// HTTP 502: a service the server depends on failed (the language model
    /// behind Sonic Sage); the associated value is the server's explanation.
    case upstreamFailure(String)
}
