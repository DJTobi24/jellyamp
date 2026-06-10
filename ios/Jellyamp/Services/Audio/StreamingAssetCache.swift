import Foundation
import JellyfinBackend

/// Progressive download-to-file cache feeding `AVAudioFile` (which needs real
/// seekable files — see docs/AUDIO-ENGINE.md).
///
/// Phase-0 scaffold: full-file download with cache hits. Progressive
/// schedule-while-downloading and ranged seeking land in Phase 1; promoting
/// entries to permanent offline storage lands in Phase 2.
final class StreamingAssetCache {
    private let session: JellyfinSession
    private let directory: URL

    init(session: JellyfinSession) {
        self.session = session
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func localFile(for itemID: String, remoteURL: URL) async throws -> URL {
        let destination = directory.appendingPathComponent(itemID)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }
        let (temporary, _) = try await URLSession.shared.download(from: remoteURL)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    func evictAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
