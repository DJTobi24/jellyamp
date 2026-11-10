import Foundation
import JellyampCore
import JellyfinBackend

/// Covers stored next to downloads so offline browsing shows artwork.
/// `ArtworkView` asks `localURL(itemID:)` first and only then the server.
///
/// Non-isolated on purpose (like `DownloadStore`): views call it while
/// rendering, the fetcher writes from a background task.
enum DownloadArtworkStore {
    static func fileURL(itemID: String) -> URL {
        DownloadStore.artworkDirectory.appendingPathComponent(DownloadFileNaming.artworkFileName(forItemID: itemID))
    }

    /// The stored cover of an album / artist / playlist / track, if any.
    static func localURL(itemID: String) -> URL? {
        let url = fileURL(itemID: itemID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Fetches the covers that are not on disk yet. Failures are ignored:
    /// artwork is decoration, and the next launch tries again.
    static func fetchMissing(itemIDs: Set<String>, session: JellyfinSession, allowsCellular: Bool) {
        let missing = itemIDs.filter { localURL(itemID: $0) == nil }.sorted()
        guard !missing.isEmpty else { return }
        Task.detached(priority: .utility) {
            for itemID in missing {
                var request = URLRequest(url: ImageURLBuilder.offlineArtworkURL(itemID: itemID, session: session))
                request.allowsCellularAccess = allowsCellular
                request.allowsExpensiveNetworkAccess = allowsCellular
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty
                else { continue }
                try? data.write(to: fileURL(itemID: itemID), options: .atomic)
            }
        }
    }

    /// Deletes covers nothing downloaded refers to any more.
    static func prune(keeping itemIDs: Set<String>) {
        let keep = Set(itemIDs.map { DownloadFileNaming.artworkFileName(forItemID: $0) })
        let directory = DownloadStore.artworkDirectory
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in contents where !keep.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
