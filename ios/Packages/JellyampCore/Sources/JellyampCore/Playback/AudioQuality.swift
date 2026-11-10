import Foundation

/// Normalises Jellyfin's `Container` strings. ffprobe reports MP4-family
/// files as a comma list ("mov,mp4,m4a,3gp,3g2,mj2"); the engine needs one
/// concrete container to pick a parser.
public enum AudioContainer {
    public static func canonical(_ container: String?) -> String? {
        guard let container, !container.isEmpty else { return nil }
        let names = container.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if names.count > 1, names.contains(where: { $0 == "m4a" || $0 == "mp4" || $0 == "mov" }) {
            return "m4a"
        }
        return names.first
    }
}

/// What the listener is actually getting for the current track — shown as the
/// quality badge on Now Playing.
public struct AudioQualityInfo: Equatable, Sendable {
    public enum Delivery: String, Equatable, Sendable {
        /// Original file streamed untouched.
        case direct
        /// Server-side transcode.
        case transcoded
        /// Original file played from local storage.
        case downloaded
    }

    public var codec: String?
    public var bitDepth: Int?
    /// Hz.
    public var sampleRate: Int?
    /// Bits per second.
    public var bitrate: Int?
    public var delivery: Delivery

    public init(codec: String?, bitDepth: Int?, sampleRate: Int?, bitrate: Int?, delivery: Delivery) {
        self.codec = codec
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
        self.bitrate = bitrate
        self.delivery = delivery
    }

    /// - Parameters:
    ///   - request: what the playback profile decided for this track
    ///   - isDownloaded: a local copy is being played (wins over `request`)
    ///   - transcodeCodec: the codec the engine really asks the server for
    public init(track: Track, request: StreamRequest, isDownloaded: Bool, transcodeCodec: String = "mp3") {
        if isDownloaded {
            self.init(codec: track.codec, bitDepth: track.bitDepth, sampleRate: track.sampleRate, bitrate: track.bitrate, delivery: .downloaded)
            return
        }
        switch request {
        case .directPlay:
            self.init(codec: track.codec, bitDepth: track.bitDepth, sampleRate: track.sampleRate, bitrate: track.bitrate, delivery: .direct)
        case .transcode(_, _, let maxBitrate):
            self.init(codec: transcodeCodec, bitDepth: nil, sampleRate: 44_100, bitrate: maxBitrate, delivery: .transcoded)
        }
    }

    public static let losslessCodecs: Set<String> = ["flac", "alac", "wav", "aiff", "pcm", "ape", "wavpack", "dsd"]

    public var isLossless: Bool {
        guard delivery != .transcoded, let codec else { return false }
        let name = codec.lowercased()
        return Self.losslessCodecs.contains(name) || name.hasPrefix("pcm_")
    }

    /// Lossless and beyond CD resolution.
    public var isHiRes: Bool {
        isLossless && ((bitDepth ?? 16) > 16 || (sampleRate ?? 44_100) > 48_000)
    }

    public var codecLabel: String {
        guard let codec, !codec.isEmpty else { return "Audio" }
        let name = codec.lowercased()
        if name.hasPrefix("pcm") { return "PCM" }
        switch name {
        case "vorbis": return "Vorbis"
        case "opus": return "Opus"
        default: return name.uppercased()
        }
    }

    /// "24-bit / 96 kHz", "44.1 kHz", or nil when nothing is known.
    public var resolutionLabel: String? {
        let rate = sampleRate.map { Self.kilohertz($0) + " kHz" }
        if isLossless, let bitDepth, let rate {
            return "\(bitDepth)-bit / \(rate)"
        }
        return rate
    }

    public var bitrateLabel: String? {
        guard let bitrate, bitrate > 0 else { return nil }
        return "\(Int((Double(bitrate) / 1000).rounded())) kbps"
    }

    /// Compact one-liner for the badge: "FLAC · 24-bit / 96 kHz · 2304 kbps".
    public var summary: String {
        [codecLabel, resolutionLabel, bitrateLabel].compactMap { $0 }.joined(separator: " · ")
    }

    static func kilohertz(_ hertz: Int) -> String {
        let value = Double(hertz) / 1000
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
