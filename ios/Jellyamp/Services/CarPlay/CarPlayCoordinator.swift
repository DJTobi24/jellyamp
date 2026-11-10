import CarPlay
import Combine
import Foundation
import MediaPlayer
import UIKit
import JellyampCore
import JellyfinBackend
import SonicClient

/// What a CarPlay list needs besides its rows: the data the rows' actions
/// refer to. Stored in the template's `userInfo`, so it lives exactly as long
/// as the template is on screen or on the navigation stack.
@MainActor
final class CarPlayPage {
    enum Role {
        case home
        case library
        case downloads
        case browse
        case queue
    }

    let role: Role
    /// The full track list behind `.playTrack(index:)`, `.playAll` and
    /// `.shuffleAll` — complete even when the visible rows were truncated.
    var tracks: [Track] = []
    var mixes: [MixDescriptor] = []
    /// Fetches the tracks for pages that list something else (an artist page
    /// lists albums, but "Shuffle All" needs the songs).
    var loadAllTracks: (() async throws -> [Track])?
    /// The library item this page stands for: radio seed and Siri donation.
    var item: MusicItemRef?
    var itemArtistName: String?

    init(role: Role) {
        self.role = role
    }
}

/// Drives the CarPlay UI: a tab bar (Home, Library, Downloads) of list
/// templates plus the shared Now Playing template with its Up Next list.
///
/// The coordinator is deliberately a thin renderer. `CarPlayListBuilder`
/// (JellyampCore, unit-tested) decides what every list contains and how it
/// is cut down to the head unit's limits; this class fetches the data, maps
/// `CarPlayItem`s to `CPListItem`s, and keeps the templates in sync with the
/// player and the session.
@MainActor
final class CarPlayCoordinator: NSObject, CPTabBarTemplateDelegate, CPNowPlayingTemplateObserver {
    private let interfaceController: CPInterfaceController
    private let container: DependencyContainer
    private let artworkLoader = CarPlayArtworkLoader()
    private let builder: CarPlayListBuilder
    private let strings: CarPlayStrings

    private var cancellables: Set<AnyCancellable> = []
    private var downloadsCancellable: AnyCancellable?
    private var isStopped = false

    private var homeTemplate: CPListTemplate?
    private var libraryTemplate: CPListTemplate?
    private var downloadsTemplate: CPListTemplate?
    private weak var queueTemplate: CPListTemplate?

    private var homeReloadTask: Task<Void, Never>?
    private var lastHomeReload = Date.distantPast

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        self.container = DependencyContainer.shared
        let strings = CarPlayStrings.localized
        self.strings = strings
        self.builder = CarPlayListBuilder(
            limits: CarPlayLimits(
                maximumItemCount: Int(CPListTemplate.maximumItemCount),
                maximumSectionCount: Int(CPListTemplate.maximumSectionCount)
            ),
            strings: strings
        )
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        // CarPlay wants a root template immediately; the session may still be
        // restoring when the car launched the app cold.
        let loading = makeMessageTemplate(title: "Jellyamp", message: String(localized: "Loading…"), detail: nil)
        interfaceController.setRootTemplate(loading, animated: false, completion: nil)
        configureNowPlayingTemplate()

        Task { [weak self] in
            await DependencyContainer.shared.waitUntilPlayable()
            guard let self, !self.isStopped else { return }
            self.observeApp()
        }
    }

    func stop() {
        isStopped = true
        cancellables.removeAll()
        downloadsCancellable = nil
        homeReloadTask?.cancel()
        CPNowPlayingTemplate.shared.remove(self)
        artworkLoader.removeAll()
    }

    /// Subscribes to everything the car UI mirrors. Each sink hops to the
    /// next main-actor turn: `@Published` emits in `willSet`, before the new
    /// value can be read back from the model.
    private func observeApp() {
        container.$session
            .map { $0?.isAuthenticated ?? false }
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.rebuildRoot() }
            }
            .store(in: &cancellables)

        // The sonic provider is wired last during bootstrap; mixes appear
        // (or disappear) on the Home tab when its capabilities are known.
        container.$sonicCapabilities
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.reloadHome() }
            }
            .store(in: &cancellables)

        let playerState = container.playerState
        playerState.$currentTrack
            .map { $0?.id }
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.currentTrackChanged() }
            }
            .store(in: &cancellables)

        playerState.$upNext
            .map { $0.map(\.id) }
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshQueue() }
            }
            .store(in: &cancellables)

        playerState.$isShuffled
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncShuffleAndRepeat() }
            }
            .store(in: &cancellables)

        playerState.$repeatMode
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncShuffleAndRepeat() }
            }
            .store(in: &cancellables)

        playerState.$errorMessage
            .removeDuplicates()
            .sink { [weak self] message in
                guard let message else { return }
                Task { @MainActor in self?.showAlert(message) }
            }
            .store(in: &cancellables)

        // The heart follows the app-wide favorite state: a like given on the
        // phone, the lock screen or by Siri shows in the car too.
        FavoritesModel.shared.$overrides
            .map(\.revision)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateNowPlayingButtons() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Root

    /// Signed in: the three tabs. Signed out: one informational list — audio
    /// apps may not show a login flow in the car.
    private func rebuildRoot() {
        guard !isStopped else { return }
        downloadsCancellable = nil
        homeReloadTask?.cancel()

        guard container.isSignedIn else {
            homeTemplate = nil
            libraryTemplate = nil
            downloadsTemplate = nil
            let model = builder.signedOut()
            let template = makeMessageTemplate(title: model.title, message: model.emptyTitle, detail: model.emptySubtitle)
            setRoot(template)
            return
        }

        let home = makeTabTemplate(title: strings.home, symbolName: "house.fill", role: .home)
        let library = makeTabTemplate(title: strings.library, symbolName: "square.stack.fill", role: .library)
        let downloads = makeTabTemplate(title: strings.downloads, symbolName: "arrow.down.circle.fill", role: .downloads)
        homeTemplate = home
        libraryTemplate = library
        downloadsTemplate = downloads

        // Until the first load finishes the tab says so instead of looking
        // empty.
        home.emptyViewTitleVariants = [String(localized: "Loading…")]
        if let page = library.userInfo as? CarPlayPage {
            render(builder.libraryRoot(), into: library, page: page)
        }
        reloadDownloads()
        reloadHome()

        // `downloads` is recreated on every sign-in, hence its own handle.
        downloadsCancellable = container.downloads?.$downloaded
            .map { $0.map(\.id) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.reloadDownloads() }
            }

        let tabBar = CPTabBarTemplate(templates: [home, library, downloads])
        tabBar.delegate = self
        setRoot(tabBar)
        syncShuffleAndRepeat()
        updateNowPlayingButtons()
    }

    private func setRoot(_ template: CPTemplate) {
        let controller = interfaceController
        if controller.presentedTemplate != nil {
            controller.dismissTemplate(animated: false, completion: nil)
        }
        if controller.templates.count > 1 {
            // Replacing the root under a pushed stack is not allowed.
            controller.popToRootTemplate(animated: false) { _, _ in
                Task { @MainActor in
                    controller.setRootTemplate(template, animated: false, completion: nil)
                }
            }
        } else {
            controller.setRootTemplate(template, animated: false, completion: nil)
        }
    }

    private func makeTabTemplate(title: String, symbolName: String, role: CarPlayPage.Role) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.tabTitle = title
        template.tabImage = UIImage(systemName: symbolName)
        template.userInfo = CarPlayPage(role: role)
        return template
    }

    /// A list with no rows shows its "empty view" text — the only way an
    /// audio app can put a plain message on the car display.
    private func makeMessageTemplate(title: String, message: String, detail: String?) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.emptyViewTitleVariants = [message]
        if let detail {
            template.emptyViewSubtitleVariants = [detail]
        }
        return template
    }

    // MARK: - Tab content

    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        if selectedTemplate === homeTemplate {
            // Coming back to Home is the natural moment to pick up what was
            // played or added meanwhile, without hammering the server.
            if Date().timeIntervalSince(lastHomeReload) > 20 {
                reloadHome()
            }
        } else if selectedTemplate === downloadsTemplate {
            reloadDownloads()
        }
    }

    private func reloadHome() {
        guard !isStopped, let template = homeTemplate else { return }
        homeReloadTask?.cancel()
        homeReloadTask = Task { [weak self] in
            await self?.loadHome(into: template)
        }
    }

    private func loadHome(into template: CPListTemplate) async {
        guard let page = template.userInfo as? CarPlayPage else { return }

        // Paint what the phone UI cached last time first: instant content on
        // a cold launch, and something to show when the car has no signal.
        let cache = container.libraryCache
        var albums = cache?.load([Album].self, for: LibraryCacheKey.recentAlbums) ?? []
        var tracks = cache?.load([Track].self, for: LibraryCacheKey.recentTracks) ?? []
        var mixes: [MixDescriptor] = []
        if container.sonicCapabilities.supports(.mixes) {
            mixes = cache?.load([MixDescriptor].self, for: LibraryCacheKey.mixes) ?? []
        }
        if page.tracks.isEmpty && page.mixes.isEmpty && template.sections.isEmpty {
            page.tracks = tracks
            page.mixes = mixes
            let cached = builder.home(mixes: mixes, recentAlbums: albums, recentTracks: tracks)
            if !cached.isEmpty {
                render(cached, into: template, page: page)
            }
        }

        guard let library = container.library else { return }
        if let fresh = try? await library.recentlyAddedAlbums(limit: 20) {
            albums = fresh
        }
        if let fresh = try? await library.recentlyPlayedTracks(limit: 20) {
            tracks = fresh
        }
        if container.sonicCapabilities.supports(.mixes),
           let sonic = container.sonic,
           let userID = container.session?.userID,
           let fresh = try? await sonic.mixes(forUser: userID) {
            mixes = fresh
        }
        guard !Task.isCancelled, !isStopped, template === homeTemplate else { return }

        page.tracks = tracks
        page.mixes = mixes
        render(builder.home(mixes: mixes, recentAlbums: albums, recentTracks: tracks), into: template, page: page)
        lastHomeReload = Date()
    }

    private func reloadDownloads() {
        guard !isStopped, let template = downloadsTemplate, let page = template.userInfo as? CarPlayPage else { return }
        let tracks = container.downloads?.downloaded ?? []
        page.tracks = tracks
        render(builder.downloads(tracks: tracks), into: template, page: page)
    }

    // MARK: - Rendering

    private func render(_ model: CarPlayListModel, into template: CPListTemplate, page: CarPlayPage) {
        template.emptyViewTitleVariants = [model.emptyTitle]
        if let subtitle = model.emptySubtitle {
            template.emptyViewSubtitleVariants = [subtitle]
        } else {
            template.emptyViewSubtitleVariants = []
        }

        let currentTrackID = container.playerState.currentTrack?.id
        var sections: [CPListSection] = []
        for section in model.sections {
            var items: [CPListItem] = []
            for item in section.items {
                items.append(makeListItem(item, page: page, currentTrackID: currentTrackID))
            }
            sections.append(CPListSection(items: items, header: section.header, sectionIndexTitle: section.indexTitle))
        }
        template.updateSections(sections)
    }

    private func makeListItem(_ item: CarPlayItem, page: CarPlayPage, currentTrackID: String?) -> CPListItem {
        let listItem = CPListItem(
            text: item.title,
            detailText: item.subtitle,
            image: UIImage(systemName: item.symbolName),
            accessoryImage: nil,
            accessoryType: item.showsDisclosure ? .disclosureIndicator : .none
        )
        // The track id rides along so the playing indicator can be moved
        // without rebuilding the list.
        listItem.userInfo = item.trackID
        listItem.playingIndicatorLocation = .trailing
        if let trackID = item.trackID {
            listItem.isPlaying = trackID == currentTrackID
        }

        let action = item.action
        if action != CarPlayAction.none {
            // CarPlay shows a spinner on the row until `completion` is called
            // — that is the loading state for every row that fetches data.
            listItem.handler = { [weak self, weak page] _, completion in
                Task { @MainActor in
                    if let self, let page {
                        await self.run(action, on: page)
                    }
                    completion()
                }
            }
        }

        if let artwork = item.artwork, let session = container.session {
            artworkLoader.load(
                artwork,
                session: session,
                pointSize: CPListItem.maximumImageSize,
                scale: interfaceController.carTraitCollection.displayScale
            ) { [weak listItem] image in
                listItem?.setImage(image)
            }
        }
        return listItem
    }

    /// All list templates currently reachable: the tabs and the pushed stack.
    private var visibleListTemplates: [CPListTemplate] {
        var result: [CPListTemplate] = []
        for template in [homeTemplate, libraryTemplate, downloadsTemplate] {
            if let template {
                result.append(template)
            }
        }
        for template in interfaceController.templates {
            if let list = template as? CPListTemplate, !result.contains(where: { $0 === list }) {
                result.append(list)
            }
        }
        return result
    }

    private func updatePlayingIndicators() {
        let currentTrackID = container.playerState.currentTrack?.id
        for template in visibleListTemplates {
            for section in template.sections {
                for item in section.items {
                    guard let listItem = item as? CPListItem, let trackID = listItem.userInfo as? String else { continue }
                    let shouldPlay = trackID == currentTrackID
                    if listItem.isPlaying != shouldPlay {
                        listItem.isPlaying = shouldPlay
                    }
                }
            }
        }
    }

    // MARK: - Row actions

    private func run(_ action: CarPlayAction, on page: CarPlayPage) async {
        do {
            try await perform(action, on: page)
        } catch {
            showAlert(message(for: error))
        }
    }

    private func makeCommands() throws -> MusicCommands {
        guard container.isSignedIn, let library = container.library, let player = container.player else {
            throw MusicCommandError.notSignedIn
        }
        return MusicCommands(container: container, library: library, player: player)
    }

    private func perform(_ action: CarPlayAction, on page: CarPlayPage) async throws {
        let commands = try makeCommands()
        switch action {
        case .browse(let destination):
            try await open(destination, commands: commands)

        case .playTrack(let index):
            guard page.tracks.indices.contains(index) else { return }
            commands.player.load(queue: PlayQueue(tracks: page.tracks, startAt: index))
            donate(page)
            showNowPlaying()

        case .playAll:
            let tracks = try await allTracks(of: page)
            commands.player.load(queue: PlayQueue(tracks: tracks))
            donate(page)
            showNowPlaying()

        case .shuffleAll:
            let tracks = try await allTracks(of: page)
            commands.player.playShuffled(tracks)
            donate(page)
            showNowPlaying()

        case .startRadio:
            guard let item = page.item else { return }
            try await commands.startRadio(from: item)
            IntentDonor.donateRadio(item)
            showNowPlaying()

        case .playMix(let id):
            guard let mix = page.mixes.first(where: { $0.id == id }) else { return }
            let tracks = try await commands.library.tracks(byIDs: mix.itemIDs)
            guard !tracks.isEmpty else { throw MusicCommandError.noPlayableTracks(mix.title) }
            commands.player.load(queue: PlayQueue(tracks: tracks))
            showNowPlaying()

        case .shuffleLikedSongs:
            try await commands.shuffleLikedSongs()
            IntentDonor.donateShuffleLikedSongs()
            showNowPlaying()

        case .jumpToUpNext(let index):
            guard container.playerState.upNext.indices.contains(index) else { return }
            commands.player.playUpNext(at: index)

        case .none:
            break
        }
    }

    private func allTracks(of page: CarPlayPage) async throws -> [Track] {
        var tracks = page.tracks
        if tracks.isEmpty, let load = page.loadAllTracks {
            tracks = try await load()
        }
        guard !tracks.isEmpty else {
            throw MusicCommandError.noPlayableTracks(page.item?.name ?? strings.songs)
        }
        return tracks
    }

    /// Tells Siri what was played by touch, so it can suggest it next time.
    private func donate(_ page: CarPlayPage) {
        guard let item = page.item else { return }
        IntentDonor.donatePlay(item, artistName: page.itemArtistName)
    }

    // MARK: - Browsing

    private func open(_ destination: CarPlayDestination, commands: MusicCommands) async throws {
        let library = commands.library
        let limit = builder.limits.maximumItemCount
        let page = CarPlayPage(role: .browse)
        let model: CarPlayListModel

        switch destination {
        case .artists:
            let artists = try await library.artists(sortBy: "SortName", startIndex: 0, limit: limit)
            model = builder.artists(artists)

        case .albums:
            let albums = try await library.albums(sortBy: "SortName", sortOrder: "Ascending", startIndex: 0, limit: limit)
            model = builder.albums(albums)

        case .playlists:
            let playlists = try await library.playlists()
            model = builder.playlists(playlists)

        case .genres:
            let genres = try await library.genres()
            model = builder.genres(genres)

        case .likedSongs:
            let tracks = try await library.favoriteTracks(limit: 500)
            page.tracks = tracks
            model = builder.trackList(
                title: strings.likedSongs,
                tracks: tracks,
                style: .mixed,
                emptyTitle: String(localized: "No Liked Songs")
            )

        case .artist(let id, let name):
            let albums = try await library.albums(byArtist: id)
            page.item = MusicItemRef(kind: .artist, id: id, name: name)
            page.loadAllTracks = { try await library.tracks(byArtist: id) }
            model = builder.artistDetail(name: name, albums: albums)

        case .album(let id, let title):
            let tracks = try await library.tracks(inAlbum: id)
            page.tracks = tracks
            page.item = MusicItemRef(kind: .album, id: id, name: title)
            page.itemArtistName = tracks.first?.artistName
            model = builder.trackList(title: title, tracks: tracks, style: .album)

        case .playlist(let id, let name):
            let tracks = try await library.tracks(inPlaylist: id)
            page.tracks = tracks
            page.item = MusicItemRef(kind: .playlist, id: id, name: name)
            model = builder.trackList(title: name, tracks: tracks, style: .mixed)

        case .genre(let id, let name):
            let tracks = try await library.tracks(inGenre: id)
            page.tracks = tracks
            page.item = MusicItemRef(kind: .genre, id: id, name: name)
            model = builder.trackList(title: name, tracks: tracks, style: .mixed, includeRadio: true)

        case .downloadedAlbum(let key, let title):
            let all = container.downloads?.downloaded ?? []
            let tracks = CarPlayListBuilder.downloadedTracks(in: all, groupKey: key)
            page.tracks = tracks
            model = builder.trackList(title: title, tracks: tracks, style: .album)
        }

        guard !isStopped else { return }
        let template = CPListTemplate(title: model.title, sections: [])
        template.userInfo = page
        render(model, into: template, page: page)
        push([template])
    }

    // MARK: - Navigation

    /// Pushes templates one after another, respecting the depth limit: when
    /// the stack is full it is unwound to the root first (CarPlay raises an
    /// exception on a push beyond the maximum depth).
    private func push(_ templates: [CPTemplate]) {
        guard !isStopped, !templates.isEmpty else { return }
        let depth = interfaceController.templates.count
        switch CarPlayNavigation.plan(stackDepth: depth, pushCount: templates.count) {
        case .push:
            pushSequentially(templates)
        case .popToRootThenPush:
            interfaceController.popToRootTemplate(animated: false) { [weak self] _, _ in
                Task { @MainActor in self?.pushSequentially(templates) }
            }
        }
    }

    private func pushSequentially(_ templates: [CPTemplate]) {
        guard !isStopped, let first = templates.first else { return }
        let rest = Array(templates.dropFirst())
        // Pushing a template that is already on the stack is a programmer
        // error CarPlay answers with an exception; skip it instead.
        if interfaceController.templates.contains(where: { $0 === first }) {
            pushSequentially(rest)
            return
        }
        interfaceController.pushTemplate(first, animated: true) { [weak self] _, _ in
            Task { @MainActor in self?.pushSequentially(rest) }
        }
    }

    private func showNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        if interfaceController.topTemplate === nowPlaying {
            return
        }
        if interfaceController.templates.contains(where: { $0 === nowPlaying }) {
            // Only the Up Next list can sit above Now Playing.
            interfaceController.popTemplate(animated: true, completion: nil)
            return
        }
        push([nowPlaying])
    }

    // MARK: - Now Playing

    private func configureNowPlayingTemplate() {
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.add(self)
        nowPlaying.isUpNextButtonEnabled = true
        nowPlaying.upNextTitle = strings.upNext
        nowPlaying.isAlbumArtistButtonEnabled = false
        updateNowPlayingButtons()
    }

    /// Shuffle, repeat and like. The like button is an image button, so it
    /// is rebuilt whenever the heart has to change.
    private func updateNowPlayingButtons() {
        let shuffle = CPNowPlayingShuffleButton { [weak self] _ in
            Task { @MainActor in self?.toggleShuffle() }
        }
        let repeatButton = CPNowPlayingRepeatButton { [weak self] _ in
            Task { @MainActor in self?.cycleRepeat() }
        }
        var buttons: [CPNowPlayingButton] = [shuffle, repeatButton]
        let symbolName = isCurrentTrackFavorite ? "heart.fill" : "heart"
        if let heart = UIImage(systemName: symbolName) {
            let favorite = CPNowPlayingImageButton(image: heart) { [weak self] _ in
                Task { @MainActor in await self?.toggleFavorite() }
            }
            buttons.append(favorite)
        }
        CPNowPlayingTemplate.shared.updateNowPlayingButtons(buttons)
    }

    private var isCurrentTrackFavorite: Bool {
        guard let track = container.playerState.currentTrack else { return false }
        return FavoritesModel.shared.isFavorite(track)
    }

    private func toggleShuffle() {
        container.player?.setShuffle(!container.playerState.isShuffled)
    }

    private func cycleRepeat() {
        container.player?.cycleRepeatMode()
    }

    private func toggleFavorite() async {
        guard container.playerState.currentTrack != nil else { return }
        let target = !isCurrentTrackFavorite
        // `FavoritesModel` flips the heart right away and puts it back if
        // the server refuses; the observer above redraws the button.
        do {
            let commands = try makeCommands()
            try await commands.setCurrentTrackFavorite(target)
        } catch {
            showAlert(message(for: error))
        }
    }

    /// The system shuffle/repeat buttons draw their state from the remote
    /// command center, not from the handlers above.
    private func syncShuffleAndRepeat() {
        let center = MPRemoteCommandCenter.shared()
        center.changeShuffleModeCommand.currentShuffleType = container.playerState.isShuffled ? .items : .off
        switch container.playerState.repeatMode {
        case .off:
            center.changeRepeatModeCommand.currentRepeatType = .off
        case .all:
            center.changeRepeatModeCommand.currentRepeatType = .all
        case .one:
            center.changeRepeatModeCommand.currentRepeatType = .one
        }
    }

    private func currentTrackChanged() {
        guard !isStopped else { return }
        updatePlayingIndicators()
        updateNowPlayingButtons()
        refreshQueue()
        // "Recently Played" just changed; refresh it the next time it is
        // cheap to do so rather than on every track.
        if Date().timeIntervalSince(lastHomeReload) > 120 {
            reloadHome()
        }
    }

    // MARK: - Up Next

    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        showQueue()
    }

    private func showQueue() {
        if let existing = queueTemplate, interfaceController.templates.contains(where: { $0 === existing }) {
            return
        }
        let template = CPListTemplate(title: strings.upNext, sections: [])
        template.userInfo = CarPlayPage(role: .queue)
        queueTemplate = template
        refreshQueue()

        if CarPlayNavigation.plan(stackDepth: interfaceController.templates.count) == .push {
            push([template])
        } else {
            // Stack is full (e.g. Artists → artist → album → Now Playing):
            // rebuild it as root → Now Playing → Up Next.
            interfaceController.popToRootTemplate(animated: false) { [weak self] _, _ in
                Task { @MainActor in
                    self?.pushSequentially([CPNowPlayingTemplate.shared, template])
                }
            }
        }
    }

    private func refreshQueue() {
        guard !isStopped, let template = queueTemplate, let page = template.userInfo as? CarPlayPage else { return }
        let playerState = container.playerState
        render(builder.queue(current: playerState.currentTrack, upNext: playerState.upNext), into: template, page: page)
    }

    // MARK: - Errors

    private func message(for error: Error) -> String {
        if let commandError = error as? MusicCommandError {
            return String(localized: commandError.localizedStringResource)
        }
        if error is URLError {
            return String(localized: "Couldn't reach your Jellyfin server. Check the connection and try again.")
        }
        return String(localized: "Something went wrong. Please try again.")
    }

    private func showAlert(_ message: String) {
        guard !isStopped else { return }
        let controller = interfaceController
        let dismiss = CPAlertAction(title: String(localized: "OK"), style: .cancel) { _ in
            Task { @MainActor in
                controller.dismissTemplate(animated: true, completion: nil)
            }
        }
        let alert = CPAlertTemplate(titleVariants: [message], actions: [dismiss])
        if controller.presentedTemplate != nil {
            // Only one modal template at a time: replace the old alert.
            controller.dismissTemplate(animated: false) { _, _ in
                Task { @MainActor in
                    controller.presentTemplate(alert, animated: true, completion: nil)
                }
            }
        } else {
            controller.presentTemplate(alert, animated: true, completion: nil)
        }
    }
}
