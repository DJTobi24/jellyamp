import Foundation

/// Lightweight on-disk cache for already-fetched library payloads (home
/// shelves, album/artist lists, …). It lets the app paint the last-known
/// content instantly on launch and refresh in the background, instead of
/// showing nothing until every request returns.
///
/// Entries are scoped per Jellyfin user so a different login never reads
/// another account's data. Stored as JSON in Application Support.
final class LibraryCache {
    private let directory: URL
    private let scope: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// `scope` identifies the account (the Jellyfin user id).
    init(scope: String) {
        self.scope = scope
        directory = Self.baseDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func load<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        guard let data = try? Data(contentsOf: fileURL(for: key)) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    func save<T: Encodable>(_ value: T, for key: String) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: fileURL(for: key), options: .atomic)
    }

    private func fileURL(for key: String) -> URL {
        let safe = "\(scope)-\(key)".replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(safe).appendingPathExtension("json")
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
}
