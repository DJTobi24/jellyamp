import Foundation
import JellyampCore

/// Lightweight on-disk cache for already-fetched library payloads (home
/// shelves, first pages of album/artist lists, …). It lets the app paint the
/// last-known content instantly on launch and refresh in the background,
/// instead of showing nothing until every request returns.
///
/// Entries are scoped per Jellyfin user so a different login never reads
/// another account's data. Stored as JSON in Application Support.
///
/// It is a cache, not a store: entries expire after 30 days, a single entry
/// may not exceed 2 MB (callers cache first pages, never whole libraries),
/// the directory is capped at 20 MB (oldest files go first), and a file that
/// cannot be decoded is discarded. The rules live in `BoundedJSONCache`
/// (JellyampCore), where they are unit-tested.
final class LibraryCache {
    private let storage: BoundedJSONCache
    /// Pruning walks the directory; keep that off the main thread.
    private let maintenanceQueue = DispatchQueue(label: "dev.djtobi.Jellyamp.LibraryCache", qos: .utility)

    /// `scope` identifies the account (the Jellyfin user id).
    init(scope: String) {
        storage = BoundedJSONCache(directory: Self.baseDirectory, scope: scope)
    }

    func load<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        storage.load(type, for: key)
    }

    func save<T: Encodable>(_ value: T, for key: String) {
        guard storage.save(value, for: key) else { return }
        maintenanceQueue.async { [storage] in storage.prune() }
    }

    func remove(for key: String) {
        storage.remove(for: key)
    }

    private static var baseDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LibraryCache", isDirectory: true)
    }

    /// Wipe everything (called on sign-out).
    static func clearAll() {
        try? FileManager.default.removeItem(at: baseDirectory)
    }
}

/// Stable cache keys for the payloads we persist.
enum LibraryCacheKey {
    static let recentAlbums = "home.recentAlbums"
    static let recentTracks = "home.recentTracks"
    static let mixes = "home.mixes"
    static let allAlbums = "library.albums"
    static let allArtists = "library.artists"
    static let playlists = "library.playlists"
    static let genres = "library.genres"
    static let likedSongs = "library.likedSongs"
}
