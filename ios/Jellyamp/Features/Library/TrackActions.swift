import SwiftUI
import JellyampCore

/// Actions on tracks, albums, artists and playlists.
///
/// Every item offers the same actions three ways: a long-press context menu
/// (`.trackContextActions(track)` etc.), a visible "⋯" button
/// (`TrackMenuButton`, `AlbumMenuButton`, …) and VoiceOver custom actions
/// (`.trackAccessibilityActions(track)`). All three are built from the same
/// button views below, so they cannot drift apart.
extension View {
    func trackContextActions(_ track: Track) -> some View {
        modifier(TrackContextActions(track: track))
    }

    /// Long-press menu for an album cover.
    func albumContextActions(_ album: Album) -> some View {
        modifier(AlbumContextActions(album: album))
    }

    /// Long-press menu for an artist row.
    func artistContextActions(_ artist: Artist) -> some View {
        modifier(ArtistContextActions(artist: artist))
    }

    /// Long-press menu for a playlist row.
    func playlistContextActions(_ playlist: Playlist) -> some View {
        modifier(PlaylistContextActions(playlist: playlist))
    }

    /// VoiceOver custom actions equal to the track's "⋯" menu, so the menu
    /// button does not have to be found on every row.
    func trackAccessibilityActions(_ track: Track) -> some View {
        modifier(TrackAccessibilityActions(track: track))
    }
}

// MARK: - Where a menu is shown

/// The album / artist screen a row is shown on, so its menu can leave out
/// "Go to Album" on that very album.
struct BrowseContext: Equatable {
    var albumID: String?
    var artistID: String?
}

private struct BrowseContextKey: EnvironmentKey {
    static let defaultValue = BrowseContext()
}

extension EnvironmentValues {
    var browseContext: BrowseContext {
        get { self[BrowseContextKey.self] }
        set { self[BrowseContextKey.self] = newValue }
    }
}

// MARK: - Operations

/// The operations behind the menu entries. A plain value built where the
/// environment is available (outside the menu) and handed to the buttons.
@MainActor
struct LibraryActions {
    let container: DependencyContainer
    /// The routed navigation stack the action comes from, if any.
    let section: AppSection?

    func play(_ tracks: [Track], startAt index: Int = 0) {
        guard !tracks.isEmpty else { return }
        container.player?.load(queue: PlayQueue(tracks: tracks, startAt: index))
    }

    func shuffle(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        container.player?.playShuffled(tracks)
    }

    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        container.player?.playNext(tracks)
        ToastCenter.shared.show(String(localized: "Playing next"), style: .success)
    }

    func enqueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        container.player?.enqueue(tracks)
        ToastCenter.shared.show(String(localized: "Added to queue"), style: .success)
    }

    func download(_ tracks: [Track]) {
        download(.tracks(tracks))
    }

    /// Downloads a named collection, so the Downloads tab lists it as that
    /// album / playlist / artist (and a playlist follows server changes).
    func download(_ target: DownloadTarget) {
        guard !target.tracks.isEmpty, let downloads = container.downloads else { return }
        switch target {
        case .tracks(let tracks): downloads.download(tracks)
        case .album(let album, let tracks): downloads.download(album: album, tracks: tracks)
        case .playlist(let playlist, let tracks): downloads.download(playlist: playlist, tracks: tracks)
        case .artist(let artist, let tracks): downloads.download(artist: artist, tracks: tracks)
        }
        ToastCenter.shared.show(String(localized: "Downloading"), style: .info)
    }

    func addToPlaylist(_ tracks: [Track], title: String) {
        guard !tracks.isEmpty else { return }
        AppNavigator.shared.playlistRequest = PlaylistAddRequest(tracks: tracks, title: title)
    }

    func toggleFavorite(itemID: String, serverValue: Bool) {
        FavoritesModel.shared.toggle(itemID: itemID, serverValue: serverValue, library: container.library)
    }

    func open(_ route: LibraryRoute?) {
        guard let route else { return }
        AppNavigator.shared.open(route, from: section)
    }

    /// Endless-radio feel from one track: with jellyamp-server this is true
    /// sonic similarity, against plain Jellyfin it's the metadata Instant Mix.
    func instantMix(from track: Track) {
        Task { @MainActor in
            guard let sonic = container.sonic, let library = container.library else { return }
            do {
                let similar = try await sonic.similarTracks(to: track.id, limit: 50)
                let mixTracks = try await library.tracks(byIDs: similar.map(\.itemID))
                guard !mixTracks.isEmpty else {
                    ToastCenter.shared.show(String(localized: "No similar tracks found"), style: .info)
                    return
                }
                container.player?.load(queue: PlayQueue(tracks: [track] + mixTracks))
            } catch {
                ToastCenter.shared.showError(String(localized: "Could not start Instant Mix"), error: error)
            }
        }
    }

    /// Fetches the tracks of a collection, then runs `action` with them;
    /// failures and empty collections are reported instead of ignored.
    func withTracks(_ load: @escaping () async throws -> [Track], perform action: @escaping ([Track]) -> Void) {
        Task { @MainActor in
            do {
                let tracks = try await load()
                if tracks.isEmpty {
                    ToastCenter.shared.show(String(localized: "Nothing to play here"), style: .info)
                } else {
                    action(tracks)
                }
            } catch {
                ToastCenter.shared.showError(String(localized: "Could not load the tracks"), error: error)
            }
        }
    }

    func albumTracks(_ album: Album) async throws -> [Track] {
        let tracks = try await container.library?.tracks(inAlbum: album.id) ?? []
        return AlbumPresentation.playbackOrder(AlbumPresentation.discSections(tracks))
    }

    func artistTracks(_ artist: Artist) async throws -> [Track] {
        try await container.library?.tracks(byArtist: artist.id) ?? []
    }

    func playlistTracks(_ playlist: Playlist) async throws -> [Track] {
        try await container.library?.tracks(inPlaylist: playlist.id) ?? []
    }
}

// MARK: - Track

private struct TrackContextActions: ViewModifier {
    @EnvironmentObject private var container: DependencyContainer
    @Environment(\.routedSection) private var section
    @Environment(\.browseContext) private var context
    let track: Track

    func body(content: Content) -> some View {
        content.contextMenu {
            TrackActionButtons(
                track: track,
                includePlay: true,
                actions: LibraryActions(container: container, section: section),
                context: context
            )
        }
    }
}

private struct TrackAccessibilityActions: ViewModifier {
    @EnvironmentObject private var container: DependencyContainer
    @Environment(\.routedSection) private var section
    @Environment(\.browseContext) private var context
    let track: Track

    func body(content: Content) -> some View {
        content.accessibilityActions {
            TrackActionButtons(
                track: track,
                includePlay: false,
                actions: LibraryActions(container: container, section: section),
                context: context,
                includeShare: false
            )
        }
    }
}

/// Visible "⋯" menu for a track row.
struct TrackMenuButton: View {
    @EnvironmentObject private var container: DependencyContainer
    @Environment(\.routedSection) private var section
    @Environment(\.browseContext) private var context
    let track: Track

    var body: some View {
        Menu {
            TrackActionButtons(
                track: track,
                includePlay: false,
                actions: LibraryActions(container: container, section: section),
                context: context
            )
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("More actions for \(track.title)"))
    }
}

/// The shared set of track actions.
private struct TrackActionButtons: View {
    @ObservedObject private var favorites = FavoritesModel.shared
    let track: Track
    let includePlay: Bool
    let actions: LibraryActions
    let context: BrowseContext
    var includeShare = true

    private var isFavorite: Bool {
        favorites.isFavorite(track.id, serverValue: track.isFavorite)
    }

    var body: some View {
        if includePlay {
            Button {
                actions.play([track])
            } label: { Label("Play", systemImage: "play.fill") }
        }
        Button {
            actions.playNext([track])
        } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button {
            actions.enqueue([track])
        } label: { Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") }
        Button {
            actions.instantMix(from: track)
        } label: { Label("Instant Mix", systemImage: "wand.and.stars") }
        TrackRadioMenuButton(track: track)
        SonicAdventureMenuButton(track: track)
        Button {
            actions.toggleFavorite(itemID: track.id, serverValue: track.isFavorite)
        } label: {
            if isFavorite {
                Label("Remove from Liked Songs", systemImage: "heart.slash")
            } else {
                Label("Add to Liked Songs", systemImage: "heart")
            }
        }
        Button {
            actions.addToPlaylist([track], title: track.title)
        } label: { Label("Add to Playlist…", systemImage: "text.badge.plus") }
        if let albumID = track.albumID, albumID != context.albumID {
            Button {
                actions.open(LibraryRoute.albumRoute(for: track))
            } label: { Label("Go to Album", systemImage: "square.stack") }
        }
        if let artistID = track.artistID, artistID != context.artistID {
            Button {
                actions.open(LibraryRoute.artistRoute(for: track))
            } label: { Label("Go to Artist", systemImage: "music.mic") }
        }
        DownloadToggleButton(track: track, downloads: actions.container.downloads)
        if includeShare {
            ShareLink(item: shareText) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var shareText: String {
        track.artistName.isEmpty ? track.title : "\(track.title) – \(track.artistName)"
    }
}

/// "Download" or "Remove Download", depending on the track's state.
private struct DownloadToggleButton: View {
    let track: Track
    let downloads: DownloadManager?

    var body: some View {
        if let downloads {
            if downloads.isDownloaded(track.id) {
                Button(role: .destructive) {
                    downloads.remove(track)
                } label: { Label("Remove Download", systemImage: "trash") }
            } else if !downloads.isInProgress(track.id) {
                Button {
                    downloads.download(track)
                } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
        }
    }
}

// MARK: - Collections (album, artist, playlist)

/// Play / Shuffle / queue / playlist / download for a lazily fetched set of
/// tracks. The tracks are fetched only when an action is chosen.
private struct CollectionActionButtons: View {
    let actions: LibraryActions
    /// Name used for the "Add to Playlist" sheet.
    let title: String
    /// What "Download" stores the fetched tracks as; plain tracks when nil.
    var downloadTarget: (([Track]) -> DownloadTarget)? = nil
    let tracks: () async throws -> [Track]

    var body: some View {
        Button {
            actions.withTracks(tracks) { actions.play($0) }
        } label: { Label("Play", systemImage: "play.fill") }
        Button {
            actions.withTracks(tracks) { actions.shuffle($0) }
        } label: { Label("Shuffle", systemImage: "shuffle") }
        Button {
            actions.withTracks(tracks) { actions.playNext($0) }
        } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button {
            actions.withTracks(tracks) { actions.enqueue($0) }
        } label: { Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") }
        Button {
            actions.withTracks(tracks) { actions.addToPlaylist($0, title: title) }
        } label: { Label("Add to Playlist…", systemImage: "text.badge.plus") }
        if actions.container.downloads != nil {
            Button {
                actions.withTracks(tracks) { actions.download(downloadTarget?($0) ?? .tracks($0)) }
            } label: { Label("Download", systemImage: "arrow.down.circle") }
        }
    }
}

/// Favorite toggle as a menu entry (albums: save, artists: follow).
private struct FavoriteMenuButton: View {
    @ObservedObject private var favorites = FavoritesModel.shared
    let itemID: String
    let serverValue: Bool
    let addTitle: String
    let removeTitle: String
    let actions: LibraryActions

    var body: some View {
        Button {
            actions.toggleFavorite(itemID: itemID, serverValue: serverValue)
        } label: {
            if favorites.isFavorite(itemID, serverValue: serverValue) {
                Label(removeTitle, systemImage: "heart.slash")
            } else {
                Label(addTitle, systemImage: "heart")
            }
        }
    }
}

/// All album actions; shared by the context menu and `AlbumMenuButton`.
private struct AlbumActionButtons: View {
    let album: Album
    let actions: LibraryActions
    let context: BrowseContext

    var body: some View {
        CollectionActionButtons(
            actions: actions,
            title: album.title,
            downloadTarget: { .album(album, tracks: $0) }
        ) {
            try await actions.albumTracks(album)
        }
        FavoriteMenuButton(
            itemID: album.id,
            serverValue: album.isFavorite,
            addTitle: String(localized: "Save Album"),
            removeTitle: String(localized: "Remove from Saved Albums"),
            actions: actions
        )
        if let artistID = album.artistID, artistID != context.artistID {
            Button {
                actions.open(LibraryRoute.artistRoute(for: album))
            } label: { Label("Go to Artist", systemImage: "music.mic") }
        }
        ShareLink(item: album.artistName.isEmpty ? album.title : "\(album.title) – \(album.artistName)") {
            Label("Share…", systemImage: "square.and.arrow.up")
        }
    }
}

private struct AlbumContextActions: ViewModifier {
    @EnvironmentObject private var container: DependencyContainer
    @Environment(\.routedSection) private var section
    @Environment(\.browseContext) private var context
    let album: Album

    func body(content: Content) -> some View {
        content.contextMenu {
            AlbumActionButtons(album: album, actions: LibraryActions(container: container, section: section), context: context)
        }
    }
}

/// Visible "⋯" menu with the album actions (album header).
struct AlbumMenuButton: View {
    @EnvironmentObject private var container: DependencyContainer
    @Environment(\.routedSection) private var section
    @Environment(\.browseContext) private var context
    let album: Album

    var body: some View {
        Menu {
            AlbumActionButtons(album: album, actions: LibraryActions(container: container, section: section), context: context)
        } label: {
            HeaderMenuLabel()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("More actions for \(album.title)"))
    }
}

private struct ArtistActionButtons: View {
    let artist: Artist
    let actions: LibraryActions

    var body: some View {
        CollectionActionButtons(
            actions: actions,
            title: artist.name,
            downloadTarget: { .artist(artist, tracks: $0) }
        ) {
            try await actions.artistTracks(artist)
        }
        FavoriteMenuButton(
            itemID: artist.id,
            serverValue: artist.isFavorite,
            addTitle: String(localized: "Follow"),
            removeTitle: String(localized: "Unfollow"),
            actions: actions
        )
        ShareLink(item: artist.name) {
            Label("Share…", systemImage: "square.and.arrow.up")
        }
    }
}

private struct ArtistContextActions: ViewModifier {
    @EnvironmentObject private var container: DependencyContainer
    @Environment(\.routedSection) private var section
    let artist: Artist

    func body(content: Content) -> some View {
        content.contextMenu {
            ArtistActionButtons(artist: artist, actions: LibraryActions(container: container, section: section))
        }
    }
}

/// Visible "⋯" menu with the artist actions (artist header).
struct ArtistMenuButton: View {
    @EnvironmentObject private var container: DependencyContainer
    @Environment(\.routedSection) private var section
    let artist: Artist

    var body: some View {
        Menu {
            ArtistActionButtons(artist: artist, actions: LibraryActions(container: container, section: section))
        } label: {
            HeaderMenuLabel()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("More actions for \(artist.name)"))
    }
}

private struct PlaylistContextActions: ViewModifier {
    @EnvironmentObject private var container: DependencyContainer
    @Environment(\.routedSection) private var section
    let playlist: Playlist

    func body(content: Content) -> some View {
        content.contextMenu {
            let actions = LibraryActions(container: container, section: section)
            CollectionActionButtons(
                actions: actions,
                title: playlist.name,
                downloadTarget: { .playlist(playlist, tracks: $0) }
            ) {
                try await actions.playlistTracks(playlist)
            }
        }
    }
}

/// Visible "⋯" menu for an already-loaded collection (genre / liked / …):
/// Play Next, Add to Queue, Add to Playlist, Download the whole set.
struct CollectionMenuButton: View {
    @EnvironmentObject private var container: DependencyContainer
    @Environment(\.routedSection) private var section
    let tracks: [Track]
    /// Name used for the "Add to Playlist" sheet; defaults to the song count.
    var title: String?

    var body: some View {
        Menu {
            let actions = LibraryActions(container: container, section: section)
            Button {
                actions.playNext(tracks)
            } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button {
                actions.enqueue(tracks)
            } label: { Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") }
            Button {
                actions.addToPlaylist(tracks, title: title ?? String(localized: "\(tracks.count) songs"))
            } label: { Label("Add to Playlist…", systemImage: "text.badge.plus") }
            if container.downloads != nil {
                Button {
                    actions.download(tracks)
                } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
        } label: {
            HeaderMenuLabel()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("More actions"))
    }
}

private struct HeaderMenuLabel: View {
    var body: some View {
        Image(systemName: "ellipsis.circle")
            .font(.title2)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

// MARK: - Favorite heart

/// Heart toggle to like a track, save an album or follow an artist (anything
/// with an item id). Flips immediately, writes to the server, and rolls back
/// with a banner if that fails. Reads through `FavoritesModel`, so every
/// heart for the same item stays in step.
struct FavoriteButton: View {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject private var favorites = FavoritesModel.shared
    let itemID: String
    private let serverValue: Bool
    private let compact: Bool

    /// - Parameter compact: a smaller heart for use inside rows.
    init(itemID: String, isFavorite: Bool, compact: Bool = false) {
        self.itemID = itemID
        self.serverValue = isFavorite
        self.compact = compact
    }

    private var isFavorite: Bool {
        favorites.isFavorite(itemID, serverValue: serverValue)
    }

    var body: some View {
        Button {
            Haptics.toggle()
            favorites.toggle(itemID: itemID, serverValue: serverValue, library: container.library)
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(compact ? .body : .title2)
                .foregroundStyle(isFavorite ? Color.pink : Color.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Favorite"))
        .accessibilityValue(isFavorite ? Text("On") : Text("Off"))
        .accessibilityAddTraits(isFavorite ? .isSelected : [])
    }
}
