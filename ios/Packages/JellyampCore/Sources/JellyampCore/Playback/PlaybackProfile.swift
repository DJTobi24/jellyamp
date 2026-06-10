import Foundation

/// Network classes that matter for the streaming decision.
public enum NetworkType: String, Codable, Sendable {
    case wifi
    case cellular
    case offline
}

/// What the client should request from `/Audio/{id}/universal`.
public enum StreamRequest: Equatable, Sendable {
    /// Original file, byte-range seekable.
    case directPlay
    /// Server-side transcode.
    case transcode(codec: String, container: String, maxBitrate: Int)
}

/// Pure decision logic: direct play whenever the device can decode the codec
/// and the bitrate fits the user's caps; otherwise transcode.
public struct PlaybackProfile: Sendable {
    /// Codecs iOS decodes natively (lowercased).
    public static let nativeCodecs: Set<String> = ["flac", "alac", "aac", "mp3", "wav", "pcm", "opus", "vorbis", "ac3", "eac3"]

    public var maxBitrateWifi: Int?
    public var maxBitrateCellular: Int?
    /// Always transcode on cellular regardless of codec (data saver).
    public var forceTranscodeOnCellular: Bool
    public var transcodeCodec: String
    public var transcodeContainer: String

    public init(
        maxBitrateWifi: Int? = nil,
        maxBitrateCellular: Int? = 320_000,
        forceTranscodeOnCellular: Bool = false,
        transcodeCodec: String = "aac",
        transcodeContainer: String = "m4a"
    ) {
        self.maxBitrateWifi = maxBitrateWifi
        self.maxBitrateCellular = maxBitrateCellular
        self.forceTranscodeOnCellular = forceTranscodeOnCellular
        self.transcodeCodec = transcodeCodec
        self.transcodeContainer = transcodeContainer
    }

    public func request(for track: Track, network: NetworkType) -> StreamRequest {
        let cap: Int? = network == .cellular ? maxBitrateCellular : maxBitrateWifi
        if network == .cellular && forceTranscodeOnCellular {
            return transcodeRequest(cap: cap)
        }
        let codecSupported = track.codec.map { Self.nativeCodecs.contains($0.lowercased()) } ?? false
        let bitrateOK = cap.map { track.bitrate.map { bitrate in bitrate <= $0 } ?? true } ?? true
        if codecSupported && bitrateOK {
            return .directPlay
        }
        return transcodeRequest(cap: cap)
    }

    private func transcodeRequest(cap: Int?) -> StreamRequest {
        .transcode(codec: transcodeCodec, container: transcodeContainer, maxBitrate: cap ?? 320_000)
    }
}
