import Foundation
import JellyampCore

/// Shared, non-isolated knowledge of where downloaded audio lives, so both the
/// `DownloadManager` (writer) and `EnginePlayer` (reader) agree on file paths
/// without crossing actor boundaries.
enum DownloadStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Downloads", isDirectory: true)
    }

    static var indexURL: URL { directory.appendingPathComponent("index.json") }

    /// File name keyed by track id; the container extension lets `AVPlayer`
    /// identify the format of the saved original file.
    static func fileName(for track: Track) -> String {
        "\(track.id).\(track.container ?? "mp3")"
    }

    static func fileURL(for track: Track) -> URL {
        directory.appendingPathComponent(fileName(for: track))
    }

    /// The local file for a track if it's fully downloaded, else nil.
    static func localURL(for track: Track) -> URL? {
        let url = fileURL(for: track)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }
}
