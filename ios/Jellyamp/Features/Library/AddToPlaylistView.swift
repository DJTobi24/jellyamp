import SwiftUI
import JellyampCore
import JellyfinBackend

/// Sheet to add one or more tracks (a song, an album, a whole list) to an
/// existing playlist or a new one. Presented by the app shell when
/// `AppNavigator.shared.playlistRequest` is set.
struct AddToPlaylistView: View {
    @EnvironmentObject private var container: DependencyContainer
    @Environment(\.dismiss) private var dismiss
    @StateObject private var loader = PagedLoader<Playlist>(pageSize: 100)
    private let tracks: [Track]
    private let title: String
    @State private var newName = ""
    @State private var showNewPlaylist = false
    @State private var working = false

    init(track: Track) {
        self.tracks = [track]
        self.title = track.title
    }

    init(request: PlaylistAddRequest) {
        self.tracks = request.tracks
        self.title = request.title
    }

    private var summary: String {
        tracks.count == 1
            ? String(localized: "Add “\(title)” to a playlist.")
            : String(localized: "Add \(tracks.count) songs from “\(title)” to a playlist.")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        newName = ""
                        showNewPlaylist = true
                    } label: {
                        Label("New Playlist", systemImage: "plus")
                            .frame(minHeight: 32)
                    }
                } footer: {
                    Text(summary)
                }
                Section("Playlists") {
                    if loader.state.isInitialLoading {
                        SkeletonRows(count: 6)
                    } else if let message = loader.state.blockingError {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(message).foregroundStyle(.secondary)
                            Button("Try Again") {
                                Task { await loader.reload(keepingItems: false) }
                            }
                        }
                    } else if loader.state.isEmpty {
                        Text("You have no playlists yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(loader.items) { playlist in
                            Button {
                                add(to: playlist)
                            } label: {
                                PlaylistListRow(playlist: playlist)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(Text("Adds to this playlist"))
                            .onAppear { loader.loadMoreIfNeeded(showing: playlist) }
                        }
                        PagingFooter(loader)
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if working { ProgressView() }
                }
            }
            .disabled(working)
            .task { await configure() }
            .alert("New Playlist", isPresented: $showNewPlaylist) {
                TextField("Name", text: $newName)
                Button("Create") { createAndAdd() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(summary)
            }
        }
        // Banners must appear above the sheet, not behind it.
        .toastHost()
    }

    private func configure() async {
        guard let browser = container.browser else { return }
        await loader.configure(key: AnyHashable("playlists")) { startIndex, limit in
            try await browser.playlistsPage(
                sort: PlaylistSortOption.name.query(), filter: .none, startIndex: startIndex, limit: limit
            )
        }
    }

    private func add(to playlist: Playlist) {
        guard let library = container.library, !tracks.isEmpty else { return }
        working = true
        Task { @MainActor in
            do {
                try await append(tracks.map(\.id), to: playlist.id, library: library)
                LibraryChanges.shared.playlistsChanged()
                ToastCenter.shared.show(String(localized: "Added to “\(playlist.name)”"), style: .success)
                dismiss()
            } catch {
                // Stay open so the user can retry or pick another playlist.
                working = false
                ToastCenter.shared.showError(String(localized: "Could not add to “\(playlist.name)”"), error: error)
            }
        }
    }

    /// The ids travel in the request's query string, and servers cap the
    /// length of a request line (8 kB by default for Jellyfin's Kestrel), so
    /// a long list is sent in batches.
    private static let batchSize = 100

    private func append(_ ids: [String], to playlistID: String, library: MusicLibraryProviding) async throws {
        var start = 0
        while start < ids.count {
            let end = min(start + Self.batchSize, ids.count)
            try await library.addToPlaylist(playlistID: playlistID, itemIDs: Array(ids[start..<end]))
            start = end
        }
    }

    private func createAndAdd() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let library = container.library else { return }
        working = true
        Task { @MainActor in
            do {
                let ids = tracks.map(\.id)
                let playlistID = try await library.createPlaylist(name: name, itemIDs: Array(ids.prefix(Self.batchSize)))
                try await append(Array(ids.dropFirst(Self.batchSize)), to: playlistID, library: library)
                LibraryChanges.shared.playlistsChanged()
                ToastCenter.shared.show(String(localized: "Created “\(name)”"), style: .success)
                dismiss()
            } catch {
                working = false
                ToastCenter.shared.showError(String(localized: "Could not create the playlist"), error: error)
            }
        }
    }
}
