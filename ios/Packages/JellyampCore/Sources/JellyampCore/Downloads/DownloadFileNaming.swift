import Foundation

/// File names for downloaded originals. The extension matters: the audio
/// engine and `AVPlayer` identify the format from it.
public enum DownloadFileNaming {
    /// Extensions we accept as-is when Jellyfin reports them as the container.
    static let knownExtensions: Set<String> = [
        "mp3", "flac", "m4a", "m4b", "mp4", "aac", "ogg", "oga", "opus", "wav", "aiff", "aif",
        "alac", "wma", "ape", "wv", "mka", "webm", "dsf", "dff", "caf",
    ]

    /// Codec → extension, for when the container is missing or unusable.
    static let extensionByCodec: [String: String] = [
        "mp3": "mp3", "flac": "flac", "aac": "m4a", "alac": "m4a", "vorbis": "ogg", "opus": "opus",
        "pcm_s16le": "wav", "pcm_s24le": "wav", "wmav2": "wma", "ape": "ape", "wavpack": "wv",
    ]

    /// Jellyfin's `Container` is normally the plain extension ("flac"), but it
    /// can be ffprobe's format list ("mov,mp4,m4a,3gp,3g2,mj2") or missing.
    public static func fileExtension(container: String?, codec: String?) -> String {
        let candidates = (container ?? "")
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if candidates.count == 1, let only = candidates.first, isSafeExtension(only) {
            return only
        }
        if candidates.contains("m4a") { return "m4a" }
        if let known = candidates.first(where: { knownExtensions.contains($0) }) { return known }
        if let codec = codec?.lowercased(), let mapped = extensionByCodec[codec] { return mapped }
        return "mp3"
    }

    public static func fileName(for track: Track) -> String {
        "\(safeID(track.id)).\(fileExtension(container: track.container, codec: track.codec))"
    }

    /// The name the pre-collection download manager used. Still looked up so
    /// files downloaded by older versions keep playing.
    public static func legacyFileName(for track: Track) -> String {
        "\(track.id).\(track.container ?? "mp3")"
    }

    /// Where a paused / failed transfer's URLSession resume data is kept.
    public static func fileName(forResumeDataOf trackID: String) -> String {
        "\(safeID(trackID)).resume"
    }

    /// Stored cover of an album / artist / playlist. The image format is
    /// whatever the server sent; decoders sniff it, so no real extension.
    public static func artworkFileName(forItemID itemID: String) -> String {
        "\(safeID(itemID)).img"
    }

    /// Short alphanumeric extensions only, so a server-supplied value can never
    /// smuggle a path separator into a file name.
    static func isSafeExtension(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 5 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Jellyfin ids are hex GUIDs; anything else is reduced to a safe subset.
    static func safeID(_ id: String) -> String {
        String(id.map { ($0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-")) ? $0 : "_" })
    }
}

/// Disk-space arithmetic for downloads.
public enum DownloadStorage {
    /// Free space we never eat into, so the system (and our own index writes)
    /// keep working when the disk is nearly full.
    public static let defaultReserveBytes: Int64 = 300 * 1024 * 1024

    /// Best guess of a track's original file size before the server tells us
    /// (bitrate × duration); used for the free-space check and storage caps.
    public static func estimatedBytes(for track: Track) -> Int64 {
        guard let bitrate = track.bitrate, bitrate > 0, track.duration > 0 else {
            // Unknown bitrate: assume ~1 MB per minute rather than zero.
            return Int64(max(track.duration, 60) / 60 * 1_048_576)
        }
        return Int64(Double(bitrate) / 8 * track.duration)
    }

    /// Whether a download of `expectedBytes` may start given the free space.
    /// An unknown free-space value (nil) never blocks a download.
    public static func canStart(expectedBytes: Int64, freeBytes: Int64?, reserveBytes: Int64 = defaultReserveBytes) -> Bool {
        guard let freeBytes else { return true }
        return freeBytes - max(expectedBytes, 0) >= reserveBytes
    }
}
