import Foundation

// Platform-independent description of the CarPlay browse tree. The app shell
// turns these values into `CPListTemplate`s 1:1; everything worth testing —
// sectioning, truncation to the head unit's limits, titles and subtitles —
// happens here, where it runs on Linux CI.

/// The head unit's list limits (`CPListTemplate.maximumItemCount` /
/// `maximumSectionCount`). They differ per car, so they are injected.
public struct CarPlayLimits: Equatable, Sendable {
    public var maximumItemCount: Int
    public var maximumSectionCount: Int

    public init(maximumItemCount: Int, maximumSectionCount: Int) {
        self.maximumItemCount = max(1, maximumItemCount)
        self.maximumSectionCount = max(1, maximumSectionCount)
    }

    /// Conservative values for tests and for the moment before a scene
    /// reports real ones.
    public static let conservative = CarPlayLimits(maximumItemCount: 100, maximumSectionCount: 30)
}

/// Which Jellyfin image to show for a row.
public struct CarPlayArtworkRef: Equatable, Hashable, Sendable {
    public var itemID: String
    public var imageTag: String?

    public init(itemID: String, imageTag: String? = nil) {
        self.itemID = itemID
        self.imageTag = imageTag
    }
}

/// A browsable page below the tab roots.
public enum CarPlayDestination: Equatable, Hashable, Sendable {
    case artists
    case albums
    case playlists
    case likedSongs
    case genres
    case artist(id: String, name: String)
    case album(id: String, title: String)
    case playlist(id: String, name: String)
    case genre(id: String, name: String)
    /// Offline tracks of one album; `key` comes from `CarPlayListBuilder.downloadGroupKey`.
    case downloadedAlbum(key: String, title: String)
}

/// What tapping a row does. Indexes refer to the page's own context (the
/// full, untruncated track list the page was built from), which the shell
/// keeps next to the template.
public enum CarPlayAction: Equatable, Sendable {
    case browse(CarPlayDestination)
    /// Play the page's tracks starting at `index`.
    case playTrack(index: Int)
    case playAll
    case shuffleAll
    /// Endless radio seeded by what the page shows (artist, genre, …).
    case startRadio
    case playMix(id: String)
    case shuffleLikedSongs
    /// Jump to an upcoming queue entry (index into `upNext`).
    case jumpToUpNext(index: Int)
    /// Informational row (e.g. the current track on the queue page).
    case none
}

public struct CarPlayItem: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var artwork: CarPlayArtworkRef?
    /// SF Symbol shown as the icon, or as placeholder until artwork loads.
    public var symbolName: String
    public var action: CarPlayAction
    /// True for rows that open another list (disclosure chevron).
    public var showsDisclosure: Bool
    /// Set on track rows so the shell can show the playing indicator.
    public var trackID: String?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        artwork: CarPlayArtworkRef? = nil,
        symbolName: String,
        action: CarPlayAction,
        showsDisclosure: Bool = false,
        trackID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.artwork = artwork
        self.symbolName = symbolName
        self.action = action
        self.showsDisclosure = showsDisclosure
        self.trackID = trackID
    }
}

public struct CarPlaySection: Equatable, Sendable {
    public var header: String?
    /// Letter for the fast-scroll index on long alphabetical lists.
    public var indexTitle: String?
    public var items: [CarPlayItem]

    public init(header: String? = nil, indexTitle: String? = nil, items: [CarPlayItem]) {
        self.header = header
        self.indexTitle = indexTitle
        self.items = items
    }
}

/// One list page, ready to be rendered.
public struct CarPlayListModel: Equatable, Sendable {
    public var title: String
    public var sections: [CarPlaySection]
    /// Shown instead of the list when there are no rows.
    public var emptyTitle: String
    public var emptySubtitle: String?
    /// True when rows were dropped to respect `CarPlayLimits`.
    public var isTruncated: Bool

    public init(
        title: String,
        sections: [CarPlaySection],
        emptyTitle: String,
        emptySubtitle: String? = nil,
        isTruncated: Bool = false
    ) {
        self.title = title
        self.sections = sections
        self.emptyTitle = emptyTitle
        self.emptySubtitle = emptySubtitle
        self.isTruncated = isTruncated
    }

    public var itemCount: Int { sections.reduce(0) { $0 + $1.items.count } }
    public var isEmpty: Bool { itemCount == 0 }
}

/// User-facing CarPlay text. English defaults live here so the builder is
/// testable; the app shell supplies localized values.
public struct CarPlayStrings: Sendable {
    public var home = "Home"
    public var library = "Library"
    public var downloads = "Downloads"
    public var quickPlay = "Quick Play"
    public var shuffleLikedSongs = "Shuffle Liked Songs"
    public var mixesForYou = "Mixes for You"
    public var recentlyAdded = "Recently Added"
    public var recentlyPlayed = "Recently Played"
    public var artists = "Artists"
    public var albums = "Albums"
    public var playlists = "Playlists"
    public var likedSongs = "Liked Songs"
    public var genres = "Genres"
    public var songs = "Songs"
    public var play = "Play"
    public var shuffle = "Shuffle"
    public var shuffleAll = "Shuffle All"
    public var startRadio = "Start Radio"
    public var nowPlaying = "Now Playing"
    public var upNext = "Up Next"
    public var unknownAlbum = "Unknown Album"
    public var nothingHere = "Nothing Here Yet"
    public var homeEmptyHint = "Play something on your iPhone and it will show up here."
    public var noDownloads = "No Downloads"
    public var noDownloadsHint = "Download music in Jellyamp on your iPhone to listen offline."
    public var queueEmpty = "Nothing Queued"
    public var signedOutTitle = "Not Signed In"
    public var signedOutHint = "Open Jellyamp on your iPhone and sign in to your Jellyfin server."
    /// "1 song" / "12 songs".
    public var songCount: @Sendable (Int) -> String = { $0 == 1 ? "1 song" : "\($0) songs" }

    public init() {}
}

/// Template depth rules. CarPlay raises an exception when an audio app
/// pushes past its maximum hierarchy depth, so every push goes through here.
public enum CarPlayNavigation {
    /// Maximum templates on the stack for audio apps, root included.
    public static let maximumDepth = 5

    public enum Plan: Equatable, Sendable {
        /// Room left: push normally.
        case push
        /// Stack is full: pop to the root first, then push.
        case popToRootThenPush
    }

    /// - Parameters:
    ///   - stackDepth: templates currently on the stack (root included).
    ///   - pushCount: templates about to be pushed (2 for "Now Playing, then
    ///     its queue" after a reset).
    public static func plan(stackDepth: Int, pushCount: Int = 1) -> Plan {
        stackDepth + pushCount <= maximumDepth ? .push : .popToRootThenPush
    }
}
