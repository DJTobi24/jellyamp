import Foundation
import JellyampCore

/// Shared, non-isolated knowledge of where downloaded audio lives, so the
/// `DownloadManager` (index owner), the background URLSession delegate
/// (writer) and the audio engine (reader) agree on file paths without
/// crossing actor boundaries.
///
/// Layout inside Application Support (excluded from iCloud/iTunes backup —
/// everything here can be fetched again from the server):
///
///     Downloads/index.json         the `DownloadIndex`
///     Downloads/genres.json        server genre id → name, for offline lookups
///     Downloads/<trackID>.<ext>    complete originals (never partial files)
///     Downloads/Resume/<trackID>   URLSession resume data of paused/failed transfers
///     Downloads/Artwork/<itemID>   covers for offline browsing
enum DownloadStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Downloads", isDirectory: true)
    }

    static var indexURL: URL { directory.appendingPathComponent("index.json") }
    static var genresURL: URL { directory.appendingPathComponent("genres.json") }
    static var resumeDirectory: URL { directory.appendingPathComponent("Resume", isDirectory: true) }
    static var artworkDirectory: URL { directory.appendingPathComponent("Artwork", isDirectory: true) }

    /// File names that live next to the audio files but are not audio.
    private static let reservedNames: Set<String> = ["index.json", "genres.json", "Resume", "Artwork"]

    /// File name keyed by track id; the container extension lets the audio
    /// engine identify the format of the saved original file.
    static func fileName(for track: Track) -> String {
        DownloadFileNaming.fileName(for: track)
    }

    static func fileURL(for track: Track) -> URL {
        directory.appendingPathComponent(fileName(for: track))
    }

    static func fileURL(named fileName: String) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// The local file for a track if it's fully downloaded, else nil. Files
    /// only appear here once a transfer finished, so existence means complete.
    static func localURL(for track: Track) -> URL? {
        registryLock.lock()
        let registered = completeFileNames[track.id]
        registryLock.unlock()
        var candidates: [String] = []
        if let registered { candidates.append(registered) }
        candidates.append(fileName(for: track))
        // Downloads made before the collection-aware index used this name.
        let legacyName = DownloadFileNaming.legacyFileName(for: track)
        if !legacyName.contains("/") { candidates.append(legacyName) }
        for name in candidates {
            let url = fileURL(named: name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Track id → file name of every complete download, published by the
    /// `DownloadManager`. The player may hold a `Track` whose container differs
    /// from the one seen at download time (list responses can lack media
    /// sources), so the name cannot always be re-derived from the track.
    private static let registryLock = NSLock()
    private static var completeFileNames: [String: String] = [:]

    static func setCompleteFileNames(_ names: [String: String]) {
        registryLock.lock()
        completeFileNames = names
        registryLock.unlock()
    }

    static func ensureDirectory() {
        let manager = FileManager.default
        for url in [directory, resumeDirectory, artworkDirectory] {
            try? manager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    /// Audio files currently in the downloads directory, with their sizes.
    static func audioFiles() -> [String: Int64] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        var files: [String: Int64] = [:]
        for url in contents {
            let name = url.lastPathComponent
            guard !reservedNames.contains(name) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files[name] = Int64(values.fileSize ?? 0)
        }
        return files
    }

    static func deleteFile(named fileName: String) {
        try? FileManager.default.removeItem(at: fileURL(named: fileName))
    }

    /// Free space the system is willing to give us, or nil if unknown.
    static func freeBytes() -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: Resume data

    static func resumeDataURL(for trackID: String) -> URL {
        resumeDirectory.appendingPathComponent(DownloadFileNaming.fileName(forResumeDataOf: trackID))
    }

    static func saveResumeData(_ data: Data, for trackID: String) {
        try? data.write(to: resumeDataURL(for: trackID), options: .atomic)
    }

    /// Returns and consumes the resume data of a track (it is only valid once).
    static func takeResumeData(for trackID: String) -> Data? {
        let url = resumeDataURL(for: trackID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return data
    }

    static func deleteResumeData(for trackID: String) {
        try? FileManager.default.removeItem(at: resumeDataURL(for: trackID))
    }

    /// Drops resume data of transfers that no longer exist.
    static func pruneResumeData(keeping trackIDs: Set<String>) {
        let keep = Set(trackIDs.map { DownloadFileNaming.fileName(forResumeDataOf: $0) })
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: resumeDirectory.path)) ?? []
        for name in contents where !keep.contains(name) {
            try? FileManager.default.removeItem(at: resumeDirectory.appendingPathComponent(name))
        }
    }

    /// Deletes everything (sign-out / "Remove all downloads").
    static func wipe() {
        try? FileManager.default.removeItem(at: directory)
        ensureDirectory()
    }
}
