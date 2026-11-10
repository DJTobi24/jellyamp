import Foundation

/// The services Jellyamp can scrobble to.
public enum ScrobbleServiceID: String, Codable, CaseIterable, Hashable, Sendable {
    case listenBrainz
    case lastFM

    public var displayName: String {
        switch self {
        case .listenBrainz: return "ListenBrainz"
        case .lastFM: return "Last.fm"
        }
    }
}

/// One play of one track, in the service-neutral shape both scrobble APIs
/// are fed from. Codable because it is what the offline queue persists.
public struct ScrobbleListen: Codable, Equatable, Hashable, Sendable {
    public var trackID: String
    public var title: String
    public var artist: String
    public var album: String?
    public var albumArtist: String?
    /// Track length in seconds; nil when unknown.
    public var duration: TimeInterval?
    public var trackNumber: Int?
    /// When this play *started* — both services want the start time.
    public var startedAt: Date

    public init(
        trackID: String,
        title: String,
        artist: String,
        album: String? = nil,
        albumArtist: String? = nil,
        duration: TimeInterval? = nil,
        trackNumber: Int? = nil,
        startedAt: Date
    ) {
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.duration = duration
        self.trackNumber = trackNumber
        self.startedAt = startedAt
    }

    public init(track: Track, startedAt: Date) {
        var album = track.albumName
        if let name = album, name.isEmpty { album = nil }
        self.init(
            trackID: track.id,
            title: track.title,
            artist: track.artistName,
            album: album,
            albumArtist: nil,
            duration: track.duration > 0 ? track.duration : nil,
            trackNumber: track.indexNumber,
            startedAt: startedAt
        )
    }

    /// Unix timestamp (seconds) of the start of the play.
    public var timestamp: Int { Int(startedAt.timeIntervalSince1970) }

    /// Identity of a play for de-duplication: the same track cannot start
    /// twice in the same second.
    public var playKey: String { "\(trackID)@\(timestamp)" }
}

/// Why a delivery to a scrobble service did not go through, reduced to what
/// the queue needs to decide: keep, retry, drop, or ask the user.
public enum ScrobbleDeliveryError: Error, Equatable, Sendable {
    /// No response from the service (offline, DNS, timeout). Not the
    /// listen's fault: keep it and do not count the attempt.
    case offline
    /// The service answered but cannot take the listen right now (rate
    /// limit, 5xx, "try again later"). Retry after the given delay if known.
    case retryLater(after: TimeInterval?, message: String)
    /// The stored token / session is no longer valid; the user must
    /// reconnect. Queued listens are kept for when they do.
    case reauthenticate(message: String)
    /// The service refused these listens for good (malformed, too old).
    /// Retrying cannot help, so they are dropped.
    case rejected(message: String)

    public var message: String {
        switch self {
        case .offline: return CoreStrings.current.scrobbleServiceUnreachable
        case .retryLater(_, let message): return message
        case .reauthenticate(let message): return message
        case .rejected(let message): return message
        }
    }
}

/// A destination the scrobble engine can deliver to. The two concrete
/// targets wrap `LastFMClient` and `ListenBrainzClient`; tests use fakes.
/// Implementations throw `ScrobbleDeliveryError`.
public protocol ScrobbleTarget: Sendable {
    var service: ScrobbleServiceID { get }
    /// Most listens accepted in one request.
    var maxBatchSize: Int { get }
    func sendNowPlaying(_ listen: ScrobbleListen) async throws
    func submit(_ listens: [ScrobbleListen]) async throws
}
