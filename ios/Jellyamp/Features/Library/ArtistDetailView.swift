import SwiftUI
import JellyampCore
import JellyfinBackend

/// One artist: header, popular songs, discography, appearances, similar
/// artists, biography.
///
/// Structure (top to bottom), each a `Section` of the list:
/// 1. `header` — picture, name, Play/Shuffle and `headerAccessories`.
/// 2. "Popular" — most played songs.
/// 3. "Albums" and "Singles & EPs" — sorted by year (toggle in the header).
/// 4. "Appears On" — albums of other artists with tracks by this one.
/// 5. "Fans Also Like", "About".
/// 6. `extraSections` — the place for sections contributed by other
///    features (sonically similar artists, artist radio, …).
///
/// While the search field is in use the sections are replaced by a paged
/// list of this artist's songs matching the text.
struct ArtistDetailView: View {
    @EnvironmentObject private var container: DependencyContainer
    @Environment(\.routedSection) private var section
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let artist: Artist
    @State private var detail: Artist?
    @State private var releases: [Album] = []
    @State private var appearsOn: [Album] = []
    @State private var topTracks: [Track] = []
    @State private var similar: [Artist] = []
    @State private var phase: LoadPhase = .loading
    @State private var newestFirst = true
    @State private var bioExpanded = false
    @State private var searchText = ""
    @StateObject private var searchLoader = PagedLoader<Track>(pageSize: 50)

    private var current: Artist { detail ?? artist }
    private var searchTerm: String? { SearchQueryPolicy.effectiveQuery(searchText) }
    private var discography: Discography { Discography(releases: releases, newestFirst: newestFirst) }
    private var bio: String? {
        let text = current.overview?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }
    private var hasContent: Bool { !releases.isEmpty || !topTracks.isEmpty || !appearsOn.isEmpty }
    private var actions: LibraryActions { LibraryActions(container: container, section: section) }

    var body: some View {
        List {
            if searchTerm != nil {
                searchResults
            } else {
                Section { header }
                if phase == .loading, !hasContent {
                    Section { SkeletonRows(count: 5) }
                } else {
                    popularSection
                    albumSection(String(localized: "Albums"), discography.albums, showsSortToggle: true)
                    albumSection(String(localized: "Singles & EPs"), discography.singlesAndEPs, showsSortToggle: discography.albums.isEmpty)
                    albumSection(String(localized: "Appears On"), Discography.sortedByYear(appearsOn, newestFirst: newestFirst), showsSortToggle: false, showsArtist: true)
                    similarSection
                    aboutSection
                    extraSections
                    if phase == .loaded, !hasContent {
                        Text("No music found for this artist.")
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .listStyle(.plain)
        .readableContentWidth()
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search songs by \(artist.name)")
        .scrollDismissesKeyboard(.immediately)
        .environment(\.browseContext, BrowseContext(albumID: nil, artistID: artist.id))
        .overlay {
            if let message = phase.errorMessage, !hasContent, searchTerm == nil {
                ErrorStateView(message: message) { Task { await load() } }
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .task(id: searchTerm) { await configureSearch() }
    }

    // MARK: - Extension points

    /// Buttons next to Play/Shuffle. Add further header buttons here.
    @ViewBuilder
    private var headerAccessories: some View {
        FavoriteButton(itemID: artist.id, isFavorite: current.isFavorite)
        ArtistDownloadButton(artist: current)
        ArtistMenuButton(artist: current)
    }

    /// Sections at the bottom of the page. Add sections from other features
    /// (sonically similar artists, artist radio, …) here; each should be a
    /// `Section` and render nothing while it has no content. `current` is
    /// the loaded artist.
    @ViewBuilder
    private var extraSections: some View {
        EmptyView()
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 12) {
            ArtworkView(itemID: artist.id, imageTag: current.imageTag, size: 160)
                .clipShape(Circle())
                .accessibilityHidden(true)
            Text(current.name)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            PlayShuffleBar(
                isEnabled: phase != .loading || hasContent,
                play: { playAll(shuffled: false) },
                shuffle: { playAll(shuffled: true) }
            ) {
                headerAccessories
            }
        }
        .frame(maxWidth: .infinity)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var popularSection: some View {
        if !topTracks.isEmpty {
            Section {
                ForEach(Array(topTracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(track: track, subtitle: .album) {
                        container.player?.load(queue: PlayQueue(tracks: topTracks, startAt: index))
                    }
                }
            } header: {
                sectionHeader(String(localized: "Popular"))
            }
        }
    }

    @ViewBuilder
    private func albumSection(_ title: String, _ items: [Album], showsSortToggle: Bool, showsArtist: Bool = false) -> some View {
        if !items.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(items) { album in
                            RouteLink(.album(album)) {
                                AlbumGridCell(album: album, showsYear: !showsArtist)
                                    .frame(width: dynamicTypeSize.isAccessibilitySize ? 220 : 150)
                            }
                            .buttonStyle(.plain)
                            .albumContextActions(album)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                .listRowSeparator(.hidden)
            } header: {
                HStack {
                    sectionHeader(title)
                    Spacer()
                    if showsSortToggle, releases.count + appearsOn.count > 1 {
                        Button {
                            newestFirst.toggle()
                        } label: {
                            Label(
                                newestFirst ? "Newest First" : "Oldest First",
                                systemImage: newestFirst ? "arrow.down" : "arrow.up"
                            )
                            .font(.caption)
                            .frame(minHeight: 44)
                        }
                        .accessibilityHint(Text("Reverses the order of the albums"))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var similarSection: some View {
        if !similar.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(similar) { other in
                            RouteLink(.artist(other)) {
                                VStack(spacing: 6) {
                                    ArtworkTile(itemID: other.id, imageTag: other.imageTag, isCircle: true, systemImage: "music.mic")
                                    Text(other.name)
                                        .font(.caption)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(width: dynamicTypeSize.isAccessibilitySize ? 160 : 110)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Text(other.name))
                                .accessibilityAddTraits(.isButton)
                            }
                            .buttonStyle(.plain)
                            .artistContextActions(other)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                .listRowSeparator(.hidden)
            } header: {
                sectionHeader(
                    container.isSonicServerActive && container.sonicCapabilities.supports(.similar)
                        ? String(localized: "Sonically Similar Artists")
                        : String(localized: "Fans Also Like")
                )
            }
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        if let bio {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(bio)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(bioExpanded ? nil : 5)
                    if bio.count > 280 {
                        Button(bioExpanded ? "Show Less" : "Show More") {
                            bioExpanded.toggle()
                        }
                        .font(.callout)
                        .frame(minHeight: 44)
                    }
                }
                .listRowSeparator(.hidden)
            } header: {
                sectionHeader(String(localized: "About"))
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.bold())
            .foregroundStyle(.primary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var searchResults: some View {
        if searchLoader.state.isInitialLoading {
            SkeletonRows()
        } else if let message = searchLoader.state.blockingError {
            Text(message)
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
        } else if searchLoader.state.isEmpty {
            Text("No songs match “\(searchText)”.")
                .foregroundStyle(.secondary)
                .listRowSeparator(.hidden)
        } else {
            ForEach(Array(searchLoader.items.enumerated()), id: \.element.id) { index, track in
                TrackRow(track: track, subtitle: .album) {
                    if let queue = PlayQueueWindow.queue(from: searchLoader.items, tappedIndex: index) {
                        container.player?.load(queue: queue)
                    }
                }
                .onAppear { searchLoader.loadMoreIfNeeded(showing: track) }
            }
            PagingFooter(searchLoader)
        }
    }

    /// All songs crediting the artist are fetched only when asked for —
    /// the page itself never needs them.
    private func playAll(shuffled: Bool) {
        let actions = self.actions
        let artist = current
        actions.withTracks({ try await actions.artistTracks(artist) }, perform: { tracks in
            if shuffled {
                actions.shuffle(tracks)
            } else {
                actions.play(tracks)
            }
        })
    }

    // MARK: - Loading

    private func load() async {
        guard let library = container.library, let browser = container.browser else { return }
        if !hasContent { phase = .loading }
        let artistID = artist.id

        // Independent requests: start them all, then collect. A failed
        // secondary shelf is simply left out; the page only reports an
        // error when its core (the discography) could not be loaded.
        let detailTask = Task { try? await library.artist(id: artistID) }
        let topTask = Task { try? await library.topTracks(byArtist: artistID, limit: 5) }
        let appearsTask = Task { try? await browser.appearsOn(artistID: artistID) }
        // One "similar artists" row: ranked by sound when jellyamp-server
        // is connected, Jellyfin's genre-based list otherwise.
        let usesSonicServer = container.isSonicServerActive && container.sonicCapabilities.supports(.similar)
        let similarTask = Task { @MainActor () -> [Artist]? in
            if usesSonicServer {
                let ranked = await SimilarLoader.artists(similarTo: artistID, limit: 12, container: container)
                if !ranked.isEmpty { return ranked }
            }
            return try? await library.similarArtists(artistID: artistID, limit: 12)
        }

        var failure: String?
        do {
            releases = try await browser.discography(artistID: artistID)
        } catch {
            if !LibraryErrorText.isCancellation(error) { failure = LibraryErrorText.message(for: error) }
        }
        if let fresh = await detailTask.value { detail = fresh }
        if let fresh = await topTask.value { topTracks = fresh }
        if let fresh = await appearsTask.value { appearsOn = fresh }
        if let fresh = await similarTask.value { similar = fresh.filter { $0.id != artistID } }

        if let failure {
            if hasContent {
                phase = .loaded
                ToastCenter.shared.show(String(localized: "Could not refresh"), detail: failure, style: .error)
            } else {
                phase = .failed(failure)
            }
        } else {
            phase = .loaded
        }
    }

    private func configureSearch() async {
        guard let term = searchTerm, let browser = container.browser else { return }
        try? await Task.sleep(nanoseconds: SearchQueryPolicy.debounceNanoseconds)
        guard !Task.isCancelled else { return }
        let filter = BrowseFilter(searchTerm: term, artistID: artist.id)
        await searchLoader.configure(key: AnyHashable(term)) { startIndex, limit in
            try await browser.tracksPage(sort: TrackSortOption.album.query(), filter: filter, startIndex: startIndex, limit: limit)
        }
    }
}
