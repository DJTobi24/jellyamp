import Foundation

/// A playable audio item. IDs are Jellyfin item IDs throughout the app.
public struct Track: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var artistName: String
    public var artistID: String?
    public var albumName: String?
    public var albumID: String?
    public var indexNumber: Int?
    public var discNumber: Int?
    public var duration: TimeInterval
    public var container: String?
    public var codec: String?
    public var bitrate: Int?
    public var sampleRate: Int?
    public var bitDepth: Int?
    /// LUFS-based gain in dB from Jellyfin (`NormalizationGain`, server ≥ 10.9).
    public var normalizationGainDB: Double?
    public var isFavorite: Bool
    public var genres: [String]
    public var productionYear: Int?
    public var imageTag: String?

    public init(
        id: String,
        title: String,
        artistName: String,
        artistID: String? = nil,
        albumName: String? = nil,
        albumID: String? = nil,
        indexNumber: Int? = nil,
        discNumber: Int? = nil,
        duration: TimeInterval,
        container: String? = nil,
        codec: String? = nil,
        bitrate: Int? = nil,
        sampleRate: Int? = nil,
        bitDepth: Int? = nil,
        normalizationGainDB: Double? = nil,
        isFavorite: Bool = false,
        genres: [String] = [],
        productionYear: Int? = nil,
        imageTag: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.artistID = artistID
        self.albumName = albumName
        self.albumID = albumID
        self.indexNumber = indexNumber
        self.discNumber = discNumber
        self.duration = duration
        self.container = container
        self.codec = codec
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.normalizationGainDB = normalizationGainDB
        self.isFavorite = isFavorite
        self.genres = genres
        self.productionYear = productionYear
        self.imageTag = imageTag
    }
}

public struct Album: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var artistName: String
    public var artistID: String?
    public var productionYear: Int?
    public var genres: [String]
    public var trackCount: Int?
    public var duration: TimeInterval?
    public var isFavorite: Bool
    public var imageTag: String?
    public var normalizationGainDB: Double?

    public init(
        id: String,
        title: String,
        artistName: String,
        artistID: String? = nil,
        productionYear: Int? = nil,
        genres: [String] = [],
        trackCount: Int? = nil,
        duration: TimeInterval? = nil,
        isFavorite: Bool = false,
        imageTag: String? = nil,
        normalizationGainDB: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.artistID = artistID
        self.productionYear = productionYear
        self.genres = genres
        self.trackCount = trackCount
        self.duration = duration
        self.isFavorite = isFavorite
        self.imageTag = imageTag
        self.normalizationGainDB = normalizationGainDB
    }
}

public struct Artist: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var genres: [String]
    public var isFavorite: Bool
    public var imageTag: String?

    public init(id: String, name: String, genres: [String] = [], isFavorite: Bool = false, imageTag: String? = nil) {
        self.id = id
        self.name = name
        self.genres = genres
        self.isFavorite = isFavorite
        self.imageTag = imageTag
    }
}

public struct Genre: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct Playlist: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var trackCount: Int?
    public var duration: TimeInterval?
    public var imageTag: String?

    public init(id: String, name: String, trackCount: Int? = nil, duration: TimeInterval? = nil, imageTag: String? = nil) {
        self.id = id
        self.name = name
        self.trackCount = trackCount
        self.duration = duration
        self.imageTag = imageTag
    }
}

/// A generated mix (Mixes for You, station results, adventures) before its
/// tracks are resolved through the library.
public struct MixDescriptor: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var description: String?
    public var seedItemIDs: [String]
    public var itemIDs: [String]

    public init(id: String, title: String, description: String? = nil, seedItemIDs: [String] = [], itemIDs: [String]) {
        self.id = id
        self.title = title
        self.description = description
        self.seedItemIDs = seedItemIDs
        self.itemIDs = itemIDs
    }
}
