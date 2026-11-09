import Foundation

/// What a station plays from. Maps onto the sonic provider's station/similar
/// calls in the app shell.
public enum StationSeed: Codable, Hashable, Sendable {
    /// Whole library, random ("Library Radio").
    case library
    case genre(name: String)
    case decade(Decade)
    /// Artist radio: the artist plus sonically/metadata-similar tracks.
    case artist(id: String)
    /// Track radio: tracks similar to one seed track.
    case track(id: String)
}

/// A startable endless station as shown on Home.
public struct StationDefinition: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var seed: StationSeed
    public var title: String
    public var subtitle: String?
    /// Jellyfin item whose artwork represents the station (artist/track
    /// radio); nil for generated stations, which get a gradient tile.
    public var artworkItemID: String?
    public var artworkImageTag: String?

    public init(
        id: String,
        seed: StationSeed,
        title: String,
        subtitle: String? = nil,
        artworkItemID: String? = nil,
        artworkImageTag: String? = nil
    ) {
        self.id = id
        self.seed = seed
        self.title = title
        self.subtitle = subtitle
        self.artworkItemID = artworkItemID
        self.artworkImageTag = artworkImageTag
    }

    public static let libraryRadio = StationDefinition(id: "station.library", seed: .library, title: "Library Radio")

    public static func genre(_ name: String) -> StationDefinition {
        StationDefinition(id: "station.genre.\(name.lowercased())", seed: .genre(name: name), title: name)
    }

    public static func decade(_ decade: Decade) -> StationDefinition {
        StationDefinition(id: "station.decade.\(decade.startYear)", seed: .decade(decade), title: decade.title)
    }

    public static func artistRadio(artistID: String, name: String, imageTag: String? = nil) -> StationDefinition {
        StationDefinition(
            id: "station.artist.\(artistID)",
            seed: .artist(id: artistID),
            title: name,
            artworkItemID: artistID,
            artworkImageTag: imageTag
        )
    }

    public static func trackRadio(for track: Track) -> StationDefinition {
        StationDefinition(
            id: "station.track.\(track.id)",
            seed: .track(id: track.id),
            title: track.title,
            subtitle: track.artistName,
            artworkItemID: track.albumID ?? track.id,
            artworkImageTag: track.imageTag
        )
    }
}

/// Builds the Home station shelves from what the library reports.
public enum StationCatalog {
    public struct Shelves: Equatable, Sendable {
        /// Library Radio, artist radios from recent listening, genre stations.
        public var stations: [StationDefinition]
        /// "Time Travel": one station per decade present in the library.
        public var timeTravel: [StationDefinition]

        public init(stations: [StationDefinition], timeTravel: [StationDefinition]) {
            self.stations = stations
            self.timeTravel = timeTravel
        }
    }

    /// - Parameters:
    ///   - hasTracks: false for an empty library — then there is nothing a
    ///     station could play and both shelves stay empty.
    ///   - recentTracks: most recent first; the first distinct artists with a
    ///     known ID become artist-radio entries.
    public static func shelves(
        hasTracks: Bool,
        genres: [Genre],
        years: [Int],
        recentTracks: [Track],
        maxArtistRadios: Int = 2,
        maxGenres: Int = 24
    ) -> Shelves {
        guard hasTracks else { return Shelves(stations: [], timeTravel: []) }

        var stations: [StationDefinition] = [.libraryRadio]

        var seenArtists = Set<String>()
        for track in recentTracks {
            guard seenArtists.count < maxArtistRadios else { break }
            guard let artistID = track.artistID, !artistID.isEmpty, !track.artistName.isEmpty,
                  seenArtists.insert(artistID).inserted else { continue }
            stations.append(.artistRadio(artistID: artistID, name: track.artistName))
        }

        var seenGenres = Set<String>()
        for genre in genres {
            guard seenGenres.count < maxGenres else { break }
            let name = genre.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seenGenres.insert(name.lowercased()).inserted else { continue }
            stations.append(.genre(name))
        }

        let timeTravel = Decade.decades(fromYears: years).map { StationDefinition.decade($0) }
        return Shelves(stations: stations, timeTravel: timeTravel)
    }
}
