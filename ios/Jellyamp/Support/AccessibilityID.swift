/// Accessibility identifiers of the controls UI tests drive.
///
/// Identifiers, unlike labels, are not localized and not read out by
/// VoiceOver, so tests written against them survive translations and copy
/// changes. This file is compiled into the app **and** into the UI-test
/// bundle (see `project.yml`), which is why it imports nothing and must stay
/// free of app types.
enum AccessibilityID {
    enum Onboarding {
        static let serverAddress = "onboarding.serverAddress"
        static let continueButton = "onboarding.continue"
        static let username = "onboarding.username"
        static let password = "onboarding.password"
        static let signIn = "onboarding.signIn"
        static let demoButton = "onboarding.demo"
    }

    /// Positions of the tab bar items (compact width). SwiftUI does not pass
    /// an identifier set inside `tabItem` on to the tab bar button, so tests
    /// address tabs by position — which, unlike the titles, is the same in
    /// every language.
    enum Tab {
        static let home = 0
        static let library = 1
        static let search = 2
        static let downloads = 3
        static let settings = 4
    }

    /// Sidebar rows (regular width).
    enum Sidebar {
        static let home = "sidebar.home"
        static let search = "sidebar.search"
        static let downloads = "sidebar.downloads"
        static let settings = "sidebar.settings"
        /// `category` is a `LibraryCategory` raw value ("albums", "songs", …).
        static func category(_ category: String) -> String { "sidebar.library.\(category)" }
    }

    enum Home {
        static func album(_ id: String) -> String { "home.album.\(id)" }
        static func track(_ id: String) -> String { "home.track.\(id)" }
        static func mix(_ id: String) -> String { "home.mix.\(id)" }
        static let adventure = "home.sonicAdventure"
    }

    enum Library {
        /// Rows of the Library root list; `category` as in `Sidebar.category`.
        static func category(_ category: String) -> String { "library.category.\(category)" }
        static let newPlaylist = "library.newPlaylist"
    }

    /// Rows and cells of library items, wherever they are listed.
    enum Item {
        static func track(_ id: String) -> String { "track.\(id)" }
        static func album(_ id: String) -> String { "album.\(id)" }
        static func artist(_ id: String) -> String { "artist.\(id)" }
        static func playlist(_ id: String) -> String { "playlist.\(id)" }
        static func genre(_ id: String) -> String { "genre.\(id)" }
    }

    /// Header buttons of an album / playlist / artist screen.
    enum Collection {
        static let play = "collection.play"
        static let shuffle = "collection.shuffle"
        static let download = "collection.download"
        static let favoritePrefix = "collection.favorite"
        /// The state is part of the identifier so a test can wait for it
        /// without reading a (localized) value.
        static func favorite(isOn: Bool) -> String { "\(favoritePrefix).\(isOn ? "on" : "off")" }
    }

    /// Entries of the track "⋯" / long-press menu.
    enum TrackMenu {
        static let playNext = "trackMenu.playNext"
        static let addToQueue = "trackMenu.addToQueue"
        static let addToPlaylist = "trackMenu.addToPlaylist"
        static let toggleFavorite = "trackMenu.toggleFavorite"
    }

    enum AddToPlaylist {
        static let newPlaylist = "addToPlaylist.new"
        static func playlist(_ id: String) -> String { "addToPlaylist.playlist.\(id)" }
        static let cancel = "addToPlaylist.cancel"
    }

    enum MiniPlayer {
        static let open = "miniPlayer.open"
        static let playPausePrefix = "miniPlayer.playPause"
        static func playPause(isPlaying: Bool) -> String { "\(playPausePrefix).\(isPlaying ? "playing" : "paused")" }
    }

    enum NowPlaying {
        static let close = "nowPlaying.close"
        static let trackInfo = "nowPlaying.trackInfo"
        static let artwork = "nowPlaying.artwork"
        static let playPausePrefix = "nowPlaying.playPause"
        static func playPause(isPlaying: Bool) -> String { "\(playPausePrefix).\(isPlaying ? "playing" : "paused")" }
        static let next = "nowPlaying.next"
        static let previous = "nowPlaying.previous"
        static let shuffle = "nowPlaying.shuffle"
        static let repeatMode = "nowPlaying.repeat"
        static let scrubber = "nowPlaying.scrubber"
        static let favoritePrefix = "nowPlaying.favorite"
        static func favorite(isOn: Bool) -> String { "\(favoritePrefix).\(isOn ? "on" : "off")" }
        static let more = "nowPlaying.more"
        static let lyrics = "nowPlaying.lyrics"
        static let visualizer = "nowPlaying.visualizer"
        static let queue = "nowPlaying.queue"
    }

    enum Queue {
        static let done = "queue.done"
        static func upNext(_ index: Int) -> String { "queue.upNext.\(index)" }
    }

    enum Lyrics {
        static let close = "lyrics.close"
        static func line(_ index: Int) -> String { "lyrics.line.\(index)" }
    }

    enum Downloads {
        static let settings = "downloads.settings"
        static let empty = "downloads.empty"
        /// A downloaded album / playlist row.
        static func collection(_ id: String) -> String { "downloads.collection.\(id)" }
        /// A row of the transfer queue.
        static func queued(_ trackID: String) -> String { "downloads.queued.\(trackID)" }
    }

    enum Settings {
        static let playback = "settings.playback"
        static let downloads = "settings.downloads"
        static let sonic = "settings.sonic"
        static let scrobbling = "settings.scrobbling"
        static let account = "settings.account"
        static let about = "settings.about"
        static let signOut = "settings.account.signOut"
    }
}
