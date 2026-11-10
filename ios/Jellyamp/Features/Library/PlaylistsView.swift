import SwiftUI
import JellyampCore
import JellyfinBackend

/// All playlists: paged list with sort options, creation and deletion.
struct PlaylistsView: View {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject private var changes = LibraryChanges.shared
    @StateObject private var loader = PagedLoader<Playlist>(pageSize: 100)
    @State private var sort = SortSelection(PlaylistSortOption.name)
    @State private var showNew = false
    @State private var newName = ""
    @State private var pendingDeletion: Playlist?

    var body: some View {
        List {
            if loader.state.isInitialLoading {
                SkeletonRows()
            } else {
                ForEach(loader.items) { playlist in
                    RouteLink(.playlist(playlist)) {
                        PlaylistListRow(playlist: playlist)
                    }
                    .playlistContextActions(playlist)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeletion = playlist
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .onAppear { loader.loadMoreIfNeeded(showing: playlist) }
                }
                PagingFooter(loader)
            }
        }
        .listStyle(.plain)
        .readableContentWidth()
        .navigationTitle("Playlists")
        .pagedListStatus(loader) {
            EmptyStateView(
                title: String(localized: "No Playlists"),
                systemImage: "music.note.list",
                message: String(localized: "Create a playlist to collect songs in your own order."),
                actionTitle: String(localized: "New Playlist"),
                action: { beginCreate() }
            )
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                SortMenu(selection: $sort)
                Button {
                    beginCreate()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(Text("New Playlist"))
                .accessibilityIdentifier(AccessibilityID.Library.newPlaylist)
            }
        }
        .alert("New Playlist", isPresented: $showNew) {
            TextField("Name", text: $newName)
            Button("Create") { create() }
            Button("Cancel", role: .cancel) { }
        }
        .confirmationDialog(
            "Delete Playlist?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { playlist in
            Button("Delete “\(playlist.name)”", role: .destructive) { delete(playlist) }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("The songs stay in your library.")
        }
        .refreshable { await loader.refresh() }
        .task(id: sort) { await configure() }
        .onChange(of: changes.playlistsRevision) { _ in
            Task { await loader.refresh() }
        }
    }

    private func configure() async {
        guard let browser = container.browser else { return }
        let query = sort.query
        let cacheable = sort == SortSelection(PlaylistSortOption.name) ? LibraryCacheKey.playlists : nil
        let cache = container.libraryCache
        await loader.configure(
            key: AnyHashable(sort),
            cached: cacheable.flatMap { cache?.load([Playlist].self, for: $0) },
            onFirstPage: { page in
                if let cacheable { cache?.save(page, for: cacheable) }
            },
            fetch: { startIndex, limit in
                try await browser.playlistsPage(sort: query, filter: .none, startIndex: startIndex, limit: limit)
            }
        )
    }

    private func beginCreate() {
        newName = ""
        showNew = true
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let library = container.library else { return }
        Task { @MainActor in
            do {
                try await library.createPlaylist(name: name, itemIDs: [])
                LibraryChanges.shared.playlistsChanged(namesChanged: true)
            } catch {
                ToastCenter.shared.showError(String(localized: "Could not create the playlist"), error: error)
            }
        }
    }

    /// Removes the row at once; puts it back if the server refuses.
    private func delete(_ playlist: Playlist) {
        guard let library = container.library else { return }
        loader.remove(id: playlist.id)
        Task { @MainActor in
            do {
                try await library.deletePlaylist(playlistID: playlist.id)
                ToastCenter.shared.show(String(localized: "Deleted “\(playlist.name)”"), style: .success)
            } catch {
                ToastCenter.shared.showError(String(localized: "Could not delete the playlist"), error: error)
                await loader.refresh()
            }
        }
    }
}
