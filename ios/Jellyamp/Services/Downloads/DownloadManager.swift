import Foundation
import Combine
import OSLog
import JellyampCore
import JellyfinBackend

/// Downloads tracks for offline playback and remembers them across launches.
/// Files are the original bytes from `/Items/{id}/File` (so quality is kept);
/// `EnginePlayer` prefers a local file via `DownloadStore` when one exists.
@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var downloaded: [Track] = []
    @Published private(set) var inProgress: [Track] = []
    @Published private(set) var failed: Set<String> = []

    private let session: JellyfinSession
    private let log = Logger(subsystem: "dev.djtobi.Jellyamp", category: "Downloads")

    init(session: JellyfinSession) {
        self.session = session
        DownloadStore.ensureDirectory()
        loadIndex()
    }

    func isDownloaded(_ trackID: String) -> Bool { downloaded.contains { $0.id == trackID } }
    func isInProgress(_ trackID: String) -> Bool { inProgress.contains { $0.id == trackID } }

    func download(_ tracks: [Track]) { tracks.forEach(download(_:)) }

    func download(_ track: Track) {
        guard !isDownloaded(track.id), !isInProgress(track.id) else { return }
        inProgress.append(track)
        failed.remove(track.id)
        let url = StreamURLBuilder.url(for: track.id, request: .directPlay, session: session)
        let destination = DownloadStore.fileURL(for: track)
        Task {
            do {
                let (temp, _) = try await URLSession.shared.download(from: url)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temp, to: destination)
                inProgress.removeAll { $0.id == track.id }
                if !downloaded.contains(where: { $0.id == track.id }) {
                    downloaded.append(track)
                }
                saveIndex()
                log.info("downloaded \(track.title, privacy: .public)")
            } catch {
                inProgress.removeAll { $0.id == track.id }
                failed.insert(track.id)
                log.error("download failed \(track.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func remove(_ track: Track) {
        try? FileManager.default.removeItem(at: DownloadStore.fileURL(for: track))
        downloaded.removeAll { $0.id == track.id }
        inProgress.removeAll { $0.id == track.id }
        failed.remove(track.id)
        saveIndex()
    }

    func clearAll() {
        try? FileManager.default.removeItem(at: DownloadStore.directory)
        DownloadStore.ensureDirectory()
        downloaded = []
        inProgress = []
        failed = []
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: DownloadStore.indexURL),
              let tracks = try? JSONDecoder().decode([Track].self, from: data) else { return }
        // Keep only entries whose file is actually present.
        downloaded = tracks.filter { DownloadStore.localURL(for: $0) != nil }
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(downloaded) {
            try? data.write(to: DownloadStore.indexURL, options: .atomic)
        }
    }
}
