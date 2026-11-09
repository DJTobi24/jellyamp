import SwiftUI
import JellyampCore

/// One album: header, tracks grouped by disc, summary footer.
///
/// Structure (top to bottom), each a `Section` of the list:
/// 1. `header` — artwork, title, artist, metadata line, Play/Shuffle and
///    `headerAccessories`.
/// 2. one section per disc (`discSections`).
/// 3. `footer` — song count and total duration.
/// 4. `extraSections` — the place for sections contributed by other
///    features (similar albums, more by this artist, …).
struct AlbumDetailView: View {
    @EnvironmentObject private var container: DependencyContainer
    @Environment(\.routedSection) private var section
    @Environment(\.browseContext) private var context
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// What the caller knew about the album; may be a stub with only an id
    /// ("Go to Album" from a track).
    let album: Album
    @State private var detail: Album?
    @State private var tracks: [Track] = []
    @State private var phase: LoadPhase = .loading
    @State private var searchText = ""

    /// The fullest version of the album we have.
    private var current: Album { detail ?? album }
    private var discs: [DiscSection] { AlbumPresentation.discSections(tracks.filtered(by: searchText)) }
    private var playbackOrder: [Track] { AlbumPresentation.playbackOrder(AlbumPresentation.discSections(tracks)) }
    private var isSearching: Bool { SearchQueryPolicy.effectiveQuery(searchText) != nil }

    /// Compilations and albums with guests name the artist on every row.
    private var showsTrackArtists: Bool {
        AlbumPresentation.showsTrackArtists(tracks: tracks, albumArtist: current.artistName)
    }

    var body: some View {
        List {
            if !isSearching {
                Section { header }
            }
            trackSections
            if phase == .loaded, !tracks.isEmpty, !isSearching {
                Section { footer }
                extraSections
            }
        }
        .listStyle(.plain)
        .readableContentWidth()
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search in album")
        .scrollDismissesKeyboard(.immediately)
        .environment(\.browseContext, BrowseContext(albumID: album.id, artistID: context.artistID))
        .overlay {
            if let message = phase.errorMessage, tracks.isEmpty {
                ErrorStateView(message: message) { Task { await load() } }
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    // MARK: - Extension points

    /// Buttons next to Play/Shuffle. Add further header buttons (download
    /// album, …) here.
    @ViewBuilder
    private var headerAccessories: some View {
        FavoriteButton(itemID: album.id, isFavorite: current.isFavorite)
        DownloadButton(album: current, tracks: tracks)
        AlbumMenuButton(album: current)
    }

    /// Sections below the track list. Add sections from other features
    /// (similar albums, more by this artist, …) here; each should be a
    /// `Section` and render nothing while it has no content. `current` is
    /// the loaded album, `tracks` its tracks.
    @ViewBuilder
    private var extraSections: some View {
        SimilarAlbumsSection(albumID: album.id, style: .listSection)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 12) {
            ArtworkView(itemID: album.id, imageTag: current.imageTag, size: 240)
                .accessibilityHidden(true)
            Text(current.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            artistLine
            if !metadataLine.isEmpty {
                Text(metadataLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            PlayShuffleBar(
                isEnabled: !tracks.isEmpty,
                play: { play(playbackOrder, at: 0) },
                shuffle: { container.player?.playShuffled(playbackOrder) }
            ) {
                headerAccessories
            }
        }
        .frame(maxWidth: .infinity)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var artistLine: some View {
        if !current.artistName.isEmpty {
            if let route = LibraryRoute.artistRoute(for: current), current.artistID != context.artistID {
                Button {
                    AppNavigator.shared.open(route, from: section)
                } label: {
                    Text(current.artistName)
                        .underline()
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Opens the artist"))
            } else {
                Text(current.artistName).foregroundStyle(.secondary)
            }
        }
    }

    private var metadataLine: String {
        AlbumPresentation.metadataLine(
            year: current.productionYear,
            genres: current.genres,
            trackCount: tracks.isEmpty ? current.trackCount : tracks.count,
            duration: tracks.isEmpty ? current.duration : AlbumPresentation.totalDuration(tracks)
        )
    }

    @ViewBuilder
    private var trackSections: some View {
        if phase == .loading, tracks.isEmpty {
            Section { SkeletonRows(count: 8, artwork: .none) }
        } else if isSearching, discs.isEmpty {
            Section {
                Text("No songs match “\(searchText)”.")
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
        } else if phase == .loaded, tracks.isEmpty {
            Section {
                Text("This album has no songs.")
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
        } else {
            let showsHeaders = AlbumPresentation.showsDiscHeaders(AlbumPresentation.discSections(tracks))
            ForEach(discs) { disc in
                Section {
                    ForEach(Array(disc.tracks.enumerated()), id: \.element.id) { position, track in
                        TrackRow(
                            track: track,
                            leading: .number(AlbumPresentation.trackNumber(for: track, positionInDisc: position)),
                            subtitle: showsTrackArtists ? .artist : .none
                        ) {
                            play(track)
                        }
                    }
                } header: {
                    if showsHeaders {
                        Label("Disc \(disc.disc)", systemImage: "opticaldisc")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
    }

    private var footer: some View {
        Text(footerText)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowSeparator(.hidden)
    }

    private var footerText: String {
        let count = tracks.count == 1 ? String(localized: "1 song") : String(localized: "\(tracks.count) songs")
        return "\(count) · \(DurationText.approximate(AlbumPresentation.totalDuration(tracks)))"
    }

    // MARK: - Actions

    /// Plays the album from the tapped track (within the search results
    /// while searching).
    private func play(_ track: Track) {
        let queue = isSearching ? AlbumPresentation.playbackOrder(discs) : playbackOrder
        guard let index = queue.firstIndex(where: { $0.id == track.id }) else { return }
        play(queue, at: index)
    }

    private func play(_ queue: [Track], at index: Int) {
        guard !queue.isEmpty else { return }
        container.player?.load(queue: PlayQueue(tracks: queue, startAt: index))
    }

    private func load() async {
        guard let library = container.library else { return }
        if tracks.isEmpty { phase = .loading }
        // The header is refreshed independently: a failure there must not
        // hide the tracks.
        let albumID = album.id
        let albumRequest = Task { try? await library.album(id: albumID) }
        do {
            let loaded = try await library.tracks(inAlbum: album.id)
            tracks = loaded
            phase = .loaded
        } catch {
            if !LibraryErrorText.isCancellation(error) {
                let message = LibraryErrorText.message(for: error)
                phase = tracks.isEmpty ? .failed(message) : .loaded
                if !tracks.isEmpty {
                    ToastCenter.shared.show(String(localized: "Could not refresh"), detail: message, style: .error)
                }
            }
        }
        let fresh: Album? = await albumRequest.value
        if let fresh {
            detail = fresh
        }
    }
}
