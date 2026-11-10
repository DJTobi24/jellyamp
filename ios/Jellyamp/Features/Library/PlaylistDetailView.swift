import SwiftUI
import PhotosUI
import JellyampCore
import JellyfinBackend

/// One playlist: header, tracks, and editing (reorder, remove, rename,
/// change image, delete).
///
/// Edits are optimistic: the list changes at once and the server call
/// follows; if it fails the list goes back to what it was and a banner says
/// why. Reordering is additionally verified against the server, because
/// Jellyfin 10.10 places moved items one row off (see `PlaylistEditing`).
struct PlaylistDetailView: View {
    @EnvironmentObject private var container: DependencyContainer
    @Environment(\.dismiss) private var dismiss
    let playlist: Playlist
    @State private var tracks: [Track] = []
    @State private var phase: LoadPhase = .loading
    /// False while further pages are still arriving; editing needs them all.
    @State private var isComplete = false
    /// True while an edit is being written; further edits wait for it.
    @State private var isSaving = false
    @State private var searchText = ""
    @State private var name: String
    @State private var artworkVersion = 0
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDelete = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false

    private let pageSize = 200

    init(playlist: Playlist) {
        self.playlist = playlist
        _name = State(initialValue: playlist.name)
    }

    private var isSearching: Bool { SearchQueryPolicy.effectiveQuery(searchText) != nil }
    private var rows: [PlaylistRow] { PlaylistEditing.rows(for: tracks.filtered(by: searchText)) }
    /// Reordering and deleting act on positions, so they need the complete,
    /// unfiltered list and server entry ids.
    private var canEdit: Bool {
        isComplete && !isSaving && !isSearching && !tracks.isEmpty && tracks.allSatisfy { $0.playlistEntryID != nil }
    }

    var body: some View {
        List {
            if !isSearching {
                Section { header }
            }
            Section {
                if phase == .loading, tracks.isEmpty {
                    SkeletonRows()
                } else if rows.isEmpty {
                    Text(isSearching ? "No songs match your search." : "This playlist is empty. Add songs from their ⋯ menu.")
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        TrackRow(track: row.track, subtitle: .artistAndAlbum) {
                            container.player?.load(queue: PlayQueue(tracks: rows.map(\.track), startAt: index))
                        }
                        .deleteDisabled(!canEdit)
                        .moveDisabled(!canEdit)
                    }
                    .onDelete { offsets in removeTracks(at: offsets) }
                    .onMove { source, destination in moveTrack(from: source, to: destination) }
                    if !isComplete, phase == .loaded {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                        .accessibilityLabel(Text("Loading more"))
                    }
                }
            }
        }
        .listStyle(.plain)
        .readableContentWidth()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search in playlist")
        .scrollDismissesKeyboard(.immediately)
        .overlay {
            if let message = phase.errorMessage, tracks.isEmpty {
                ErrorStateView(message: message) { Task { await reload() } }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if canEdit || isSaving {
                    EditButton().disabled(isSaving)
                }
                Menu {
                    Button { renameText = name; showRename = true } label: { Label("Rename", systemImage: "pencil") }
                    Button { showPhotoPicker = true } label: { Label("Change Image", systemImage: "photo") }
                    if !tracks.isEmpty {
                        Button {
                            AppNavigator.shared.playlistRequest = PlaylistAddRequest(tracks: tracks, title: name)
                        } label: { Label("Add to Another Playlist…", systemImage: "text.badge.plus") }
                        // Only once every page is loaded: the download
                        // covers exactly the tracks it is given.
                        if let downloads = container.downloads, isComplete {
                            Button {
                                downloads.download(playlist: currentPlaylist, tracks: tracks)
                            } label: { Label("Download", systemImage: "arrow.down.circle") }
                        }
                    }
                    ShareLink(item: name) { Label("Share…", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { showDelete = true } label: { Label("Delete Playlist", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(Text("Playlist actions"))
            }
        }
        .alert("Rename Playlist", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) { }
        }
        .alert("Delete Playlist?", isPresented: $showDelete) {
            Button("Delete", role: .destructive) { deletePlaylist() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("\u{201C}\(name)\u{201D} will be removed. The songs stay in your library.")
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .task(id: photoItem) { await uploadImageIfNeeded() }
        .refreshable { await reload() }
        .task { await reload() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            ArtworkView(itemID: playlist.id, imageTag: playlist.imageTag, size: 240)
                .id(artworkVersion)
                .accessibilityHidden(true)
            Text(name)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if !summary.isEmpty {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            PlayShuffleBar(
                isEnabled: !tracks.isEmpty,
                play: { container.player?.load(queue: PlayQueue(tracks: tracks, startAt: 0)) },
                shuffle: { container.player?.playShuffled(tracks) }
            ) {
                // Downloads the playlist as a playlist: it then shows under
                // Playlists in Downloads and follows later changes. Disabled
                // until all pages are loaded (an empty track list).
                DownloadButton(playlist: currentPlaylist, tracks: isComplete ? tracks : [])
            }
        }
        .frame(maxWidth: .infinity)
        .listRowSeparator(.hidden)
    }

    /// The playlist as it is now (after a rename in this screen).
    private var currentPlaylist: Playlist {
        var current = playlist
        current.name = name
        return current
    }

    private var summary: String {
        guard isComplete, !tracks.isEmpty else { return "" }
        return AlbumPresentation.metadataLine(
            year: nil, genres: [], trackCount: tracks.count, duration: AlbumPresentation.totalDuration(tracks)
        )
    }

    // MARK: - Loading

    /// Loads the playlist page by page: the first page shows immediately,
    /// the rest follows. A playlist is loaded completely (unlike library
    /// lists) because playing and reordering need every entry.
    private func reload() async {
        guard !isSaving else { return }
        if tracks.isEmpty { phase = .loading }
        do {
            let loaded = try await fetchAll { partial in
                // Show progress only on the first load; a refresh keeps the
                // current rows until the new list is complete.
                if !isComplete { tracks = partial; phase = .loaded }
            }
            tracks = loaded
            isComplete = true
            phase = .loaded
        } catch {
            guard !LibraryErrorText.isCancellation(error) else { return }
            let message = LibraryErrorText.message(for: error)
            if tracks.isEmpty {
                phase = .failed(message)
            } else {
                phase = .loaded
                ToastCenter.shared.show(String(localized: "Could not refresh"), detail: message, style: .error)
            }
        }
    }

    private func fetchAll(progress: (([Track]) -> Void)? = nil) async throws -> [Track] {
        guard let browser = container.browser else { throw LibraryBrowseError.unavailable }
        var state = PagedListState<PlaylistRow>(pageSize: pageSize)
        var collected: [Track] = []
        var request: PageRequest? = state.beginReload()
        while let current = request {
            try Task.checkCancellation()
            let page = try await browser.playlistTracksPage(playlistID: playlist.id, startIndex: current.startIndex, limit: current.limit)
            collected.append(contentsOf: page.items)
            // The paging state only drives the offsets here; rows are keyed
            // by position so repeated tracks do not count as duplicates.
            let rows = page.items.enumerated().map { PlaylistRow(id: "\(current.startIndex + $0.offset)", track: $0.element) }
            state.receive(Page(items: rows, totalCount: page.totalCount), for: current)
            request = state.beginNextPage()
            if request != nil { progress?(collected) }
        }
        return collected
    }

    // MARK: - Editing

    private func removeTracks(at offsets: IndexSet) {
        guard canEdit, let library = container.library else { return }
        let snapshot = tracks
        let result = PlaylistEditing.removing(offsets, from: tracks)
        guard !result.entryIDs.isEmpty else { return }
        tracks = result.remaining
        isSaving = true
        Task { @MainActor in
            do {
                try await library.removeFromPlaylist(playlistID: playlist.id, entryIDs: result.entryIDs)
                LibraryChanges.shared.playlistsChanged()
            } catch {
                tracks = snapshot
                ToastCenter.shared.showError(String(localized: "Could not remove the song"), error: error)
            }
            isSaving = false
        }
    }

    private func moveTrack(from source: IndexSet, to destination: Int) {
        guard canEdit, let library = container.library, let from = source.first,
              let moved = PlaylistEditing.moving(tracks, from: from, toOffset: destination),
              let entryID = tracks[from].playlistEntryID else { return }
        let snapshot = tracks
        tracks = moved.result
        let expected = moved.result.compactMap(\.playlistEntryID)
        isSaving = true
        Task { @MainActor in
            do {
                try await library.movePlaylistItem(playlistID: playlist.id, entryID: entryID, toIndex: moved.finalIndex)
                try await reconcileOrder(expected: expected, library: library)
            } catch {
                tracks = snapshot
                ToastCenter.shared.showError(String(localized: "Could not move the song"), error: error)
            }
            isSaving = false
        }
    }

    /// Compares the server's order with the one on screen. If they differ —
    /// Jellyfin 10.10 inserts moved items one row off — the corrective moves
    /// for that behaviour are sent; whatever the server holds afterwards is
    /// what the list shows, so screen and server never disagree.
    private func reconcileOrder(expected: [String], library: MusicLibraryProviding) async throws {
        var server = try await fetchAll()
        var serverOrder = server.compactMap(\.playlistEntryID)
        if serverOrder != expected,
           let corrections = PlaylistEditing.legacyMoveOperations(current: serverOrder, desired: expected) {
            for operation in corrections {
                try await library.movePlaylistItem(playlistID: playlist.id, entryID: operation.entryID, toIndex: operation.index)
            }
            server = try await fetchAll()
            serverOrder = server.compactMap(\.playlistEntryID)
        }
        tracks = server
        if serverOrder != expected {
            ToastCenter.shared.show(
                String(localized: "The server ordered the playlist differently."),
                style: .info
            )
        }
    }

    private func rename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != name, let library = container.library else { return }
        let previous = name
        name = trimmed
        Task { @MainActor in
            do {
                try await library.renamePlaylist(playlistID: playlist.id, name: trimmed)
                LibraryChanges.shared.playlistsChanged(namesChanged: true)
            } catch {
                name = previous
                ToastCenter.shared.showError(String(localized: "Could not rename the playlist"), error: error)
            }
        }
    }

    private func deletePlaylist() {
        guard let library = container.library else { return }
        Task { @MainActor in
            do {
                try await library.deletePlaylist(playlistID: playlist.id)
                LibraryChanges.shared.playlistsChanged(namesChanged: true)
                dismiss()
            } catch {
                ToastCenter.shared.showError(String(localized: "Could not delete the playlist"), error: error)
            }
        }
    }

    private func uploadImageIfNeeded() async {
        guard let photoItem else { return }
        defer { self.photoItem = nil }
        guard let library = container.library else { return }
        do {
            guard let data = try await photoItem.loadTransferable(type: Data.self),
                  let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) else {
                ToastCenter.shared.show(String(localized: "This image could not be read."), style: .error)
                return
            }
            try await library.setPlaylistImage(playlistID: playlist.id, jpeg: jpeg)
            artworkVersion += 1
            LibraryChanges.shared.playlistsChanged()
        } catch {
            ToastCenter.shared.showError(String(localized: "Could not change the image"), error: error)
        }
    }
}
