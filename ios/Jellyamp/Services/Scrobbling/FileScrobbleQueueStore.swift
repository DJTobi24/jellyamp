import Foundation
import JellyampCore

/// The offline scrobble queue as one JSON file in Application Support, so
/// listens made without a connection survive relaunches (and are included
/// in device backups). The queue is small and capped by `ScrobbleQueuePolicy`,
/// so rewriting the whole file on each change is fine.
final class FileScrobbleQueueStore: ScrobbleQueueStoring, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Scrobbling", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("queue.json")
    }

    func loadPendingScrobbles() -> [PendingScrobble] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([PendingScrobble].self, from: data) else {
            return []
        }
        return entries
    }

    func save(pendingScrobbles: [PendingScrobble]) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(pendingScrobbles) else { return }
        // Scrobbles are written while music plays on a locked phone, so the
        // file must stay writable after the first unlock.
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
