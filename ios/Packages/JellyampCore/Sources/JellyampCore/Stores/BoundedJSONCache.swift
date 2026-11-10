import Foundation

/// A small JSON file cache with the bounds a cache needs:
///
/// - an entry older than `maxAge` is ignored and deleted,
/// - an entry larger than `maxEntryBytes` is not written,
/// - when the directory exceeds `maxTotalBytes` the oldest files go first,
/// - a file that cannot be decoded (truncated write, model change after an
///   update, another format version) counts as a miss and is deleted instead
///   of failing on every launch.
///
/// Entries are namespaced by `scope` (the signed-in user), so one account
/// never reads another's data.
public final class BoundedJSONCache: @unchecked Sendable {
    public let directory: URL
    private let scope: String
    private let maxAge: TimeInterval
    private let maxEntryBytes: Int
    private let maxTotalBytes: Int
    private let now: @Sendable () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Bump when a cached model changes so that old files would decode
    /// *wrongly* (files that fail to decode are discarded anyway).
    static let formatVersion = 1

    public init(
        directory: URL,
        scope: String,
        maxAge: TimeInterval = 30 * 24 * 3600,
        maxEntryBytes: Int = 2_000_000,
        maxTotalBytes: Int = 20_000_000,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.scope = scope
        self.maxAge = maxAge
        self.maxEntryBytes = maxEntryBytes
        self.maxTotalBytes = maxTotalBytes
        self.now = now
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func load<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let envelope = try? decoder.decode(Envelope<T>.self, from: data),
              envelope.version == Self.formatVersion,
              abs(now().timeIntervalSince(envelope.savedAt)) <= maxAge else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return envelope.payload
    }

    /// Returns false when the value was not stored (too large or not
    /// encodable); whatever was cached under the key before is removed then,
    /// so a stale payload is never served in its place.
    @discardableResult
    public func save<T: Encodable>(_ value: T, for key: String) -> Bool {
        let url = fileURL(for: key)
        let envelope = Envelope(version: Self.formatVersion, savedAt: now(), payload: value)
        guard let data = try? encoder.encode(envelope), data.count <= maxEntryBytes else {
            try? FileManager.default.removeItem(at: url)
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    public func remove(for key: String) {
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    /// Deletes the least recently written files (of any scope) until the
    /// directory fits `maxTotalBytes`. Walks the directory, so call it off
    /// the main thread.
    public func prune() {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        var files: [(url: URL, size: Int, modified: Date)] = []
        var total = 0
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            let size = values.fileSize ?? 0
            total += size
            files.append((url, size, values.contentModificationDate ?? .distantPast))
        }
        guard total > maxTotalBytes else { return }
        for file in files.sorted(by: { $0.modified < $1.modified }) {
            try? manager.removeItem(at: file.url)
            total -= file.size
            if total <= maxTotalBytes { break }
        }
    }

    func fileURL(for key: String) -> URL {
        let safe = "\(scope)-\(key)"
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent(safe).appendingPathExtension("json")
    }
}

/// Wraps a payload with what is needed to judge its freshness.
private struct Envelope<Payload> {
    var version: Int
    var savedAt: Date
    var payload: Payload
}

extension Envelope: Decodable where Payload: Decodable {}
extension Envelope: Encodable where Payload: Encodable {}
