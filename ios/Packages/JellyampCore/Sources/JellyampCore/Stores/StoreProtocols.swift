import Foundation

/// Local metadata cache (GRDB on device, in-memory fake in tests).
public protocol MetadataStoring {
    func upsert(tracks: [Track]) throws
    func upsert(albums: [Album]) throws
    func upsert(artists: [Artist]) throws
    func track(id: String) throws -> Track?
    func searchTracks(query: String, limit: Int) throws -> [Track]
}

/// Download lifecycle a track can be in.
public enum DownloadState: String, Codable, Sendable {
    case queued
    case downloading
    case complete
    case failed
}

public struct DownloadRecord: Codable, Equatable, Sendable {
    public var trackID: String
    public var state: DownloadState
    public var filePath: String?
    public var bytesDownloaded: Int64
    public var totalBytes: Int64?

    public init(trackID: String, state: DownloadState, filePath: String? = nil, bytesDownloaded: Int64 = 0, totalBytes: Int64? = nil) {
        self.trackID = trackID
        self.state = state
        self.filePath = filePath
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
    }
}

public protocol DownloadStoring {
    func upsert(_ record: DownloadRecord) throws
    func record(trackID: String) throws -> DownloadRecord?
    func allRecords() throws -> [DownloadRecord]
    func delete(trackID: String) throws
}

/// Settings persistence (UserDefaults on device, dictionary in tests).
public protocol SettingsStoring {
    func loadSettings() -> AppSettings
    func save(_ settings: AppSettings)
}
