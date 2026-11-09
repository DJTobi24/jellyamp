import Foundation

public enum SortDirection: String, Codable, Sendable, CaseIterable {
    case ascending = "Ascending"
    case descending = "Descending"

    public var toggled: SortDirection { self == .ascending ? .descending : .ascending }
}

/// The `sortBy` / `sortOrder` pair sent to Jellyfin's `/Items`.
public struct LibrarySortQuery: Equatable, Sendable {
    public var sortBy: String
    public var sortOrder: String

    public init(sortBy: String, sortOrder: String) {
        self.sortBy = sortBy
        self.sortOrder = sortOrder
    }

    /// Jellyfin pairs the n-th `sortOrder` with the n-th `sortBy` key. The
    /// primary key follows `direction`; tie-breakers always ascend, so
    /// "newest first" still lists same-year albums A→Z.
    static func make(primary: String, tieBreakers: [String], direction: SortDirection) -> LibrarySortQuery {
        let keys = [primary] + tieBreakers
        let orders = [direction.rawValue] + tieBreakers.map { _ in SortDirection.ascending.rawValue }
        return LibrarySortQuery(sortBy: keys.joined(separator: ","), sortOrder: orders.joined(separator: ","))
    }
}

/// What every sortable list offers. Raw values are persisted (last used sort).
public protocol LibrarySortOption: CaseIterable, Hashable, Sendable {
    /// Direction used when the option is first chosen.
    var defaultDirection: SortDirection { get }
    /// False for orders without a meaningful direction (random).
    var supportsDirection: Bool { get }
    /// Whether an A–Z jump index makes sense for this order.
    var isAlphabetical: Bool { get }
    func query(direction: SortDirection) -> LibrarySortQuery
}

extension LibrarySortOption {
    public var supportsDirection: Bool { true }
    public var isAlphabetical: Bool { false }

    public func query() -> LibrarySortQuery { query(direction: defaultDirection) }

    /// The A–Z index only works while the list really runs A→Z.
    public func showsAlphabetIndex(direction: SortDirection) -> Bool {
        isAlphabetical && direction == .ascending
    }
}

public enum AlbumSortOption: String, LibrarySortOption, Identifiable, Codable {
    case name, artist, year, recentlyAdded, random

    public var id: String { rawValue }

    public var defaultDirection: SortDirection {
        switch self {
        case .name, .artist, .random: return .ascending
        case .year, .recentlyAdded: return .descending
        }
    }

    public var supportsDirection: Bool { self != .random }
    public var isAlphabetical: Bool { self == .name }

    public func query(direction: SortDirection) -> LibrarySortQuery {
        switch self {
        case .name: return .make(primary: "SortName", tieBreakers: [], direction: direction)
        case .artist: return .make(primary: "AlbumArtist", tieBreakers: ["ProductionYear", "SortName"], direction: direction)
        case .year: return .make(primary: "ProductionYear", tieBreakers: ["SortName"], direction: direction)
        case .recentlyAdded: return .make(primary: "DateCreated", tieBreakers: ["SortName"], direction: direction)
        case .random: return LibrarySortQuery(sortBy: "Random", sortOrder: SortDirection.ascending.rawValue)
        }
    }
}

public enum ArtistSortOption: String, LibrarySortOption, Identifiable, Codable {
    case name, recentlyAdded, random

    public var id: String { rawValue }

    public var defaultDirection: SortDirection { self == .recentlyAdded ? .descending : .ascending }
    public var supportsDirection: Bool { self != .random }
    public var isAlphabetical: Bool { self == .name }

    public func query(direction: SortDirection) -> LibrarySortQuery {
        switch self {
        case .name: return .make(primary: "SortName", tieBreakers: [], direction: direction)
        case .recentlyAdded: return .make(primary: "DateCreated", tieBreakers: ["SortName"], direction: direction)
        case .random: return LibrarySortQuery(sortBy: "Random", sortOrder: SortDirection.ascending.rawValue)
        }
    }
}

public enum TrackSortOption: String, LibrarySortOption, Identifiable, Codable {
    case title, album, artist, recentlyAdded, mostPlayed, year, duration, random

    public var id: String { rawValue }

    public var defaultDirection: SortDirection {
        switch self {
        case .title, .album, .artist, .random: return .ascending
        case .recentlyAdded, .mostPlayed, .year, .duration: return .descending
        }
    }

    public var supportsDirection: Bool { self != .random }
    public var isAlphabetical: Bool { self == .title }

    public func query(direction: SortDirection) -> LibrarySortQuery {
        switch self {
        // Not `SortName`: Jellyfin builds an audio item's sort name from its
        // disc and track number ("0001 - Title"), so sorting songs by
        // SortName yields all track 1s, then all track 2s. `Name` is the
        // title. The same prefix makes SortName the right tie-breaker inside
        // an album (it is disc/track order).
        case .title: return .make(primary: "Name", tieBreakers: [], direction: direction)
        case .album: return .make(primary: "Album", tieBreakers: ["SortName"], direction: direction)
        case .artist: return .make(primary: "Artist", tieBreakers: ["Album", "SortName"], direction: direction)
        case .recentlyAdded: return .make(primary: "DateCreated", tieBreakers: ["Album", "SortName"], direction: direction)
        case .mostPlayed: return .make(primary: "PlayCount", tieBreakers: ["Name"], direction: direction)
        case .year: return .make(primary: "ProductionYear", tieBreakers: ["Album", "SortName"], direction: direction)
        case .duration: return .make(primary: "Runtime", tieBreakers: ["Name"], direction: direction)
        case .random: return LibrarySortQuery(sortBy: "Random", sortOrder: SortDirection.ascending.rawValue)
        }
    }
}

public enum PlaylistSortOption: String, LibrarySortOption, Identifiable, Codable {
    case name, recentlyAdded

    public var id: String { rawValue }

    public var defaultDirection: SortDirection { self == .name ? .ascending : .descending }

    public func query(direction: SortDirection) -> LibrarySortQuery {
        switch self {
        case .name: return .make(primary: "SortName", tieBreakers: [], direction: direction)
        case .recentlyAdded: return .make(primary: "DateCreated", tieBreakers: ["SortName"], direction: direction)
        }
    }
}

/// A sort option together with its direction — what a list screen keeps as
/// state and what identifies a distinct server query.
public struct SortSelection<Option: LibrarySortOption>: Hashable, Sendable {
    public var option: Option
    public var direction: SortDirection

    public init(_ option: Option, direction: SortDirection? = nil) {
        self.option = option
        self.direction = direction ?? option.defaultDirection
    }

    public var query: LibrarySortQuery { option.query(direction: direction) }
    public var showsAlphabetIndex: Bool { option.showsAlphabetIndex(direction: direction) }

    /// Choosing the active option again flips its direction (when it has
    /// one); choosing another option starts with that option's default.
    public mutating func select(_ newOption: Option) {
        if newOption == option {
            if option.supportsDirection { direction = direction.toggled }
        } else {
            option = newOption
            direction = newOption.defaultDirection
        }
    }
}
