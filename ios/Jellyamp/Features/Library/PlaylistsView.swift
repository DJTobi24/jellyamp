import SwiftUI
import JellyampCore

struct PlaylistsView: View {
    @EnvironmentObject private var container: DependencyContainer
    @State private var playlists: [Playlist] = []

    @State private var showNew = false
    @State private var newName = ""

    var body: some View {
        List(playlists) { playlist in
            NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                HStack {
                    ArtworkView(itemID: playlist.id, imageTag: playlist.imageTag, size: 44)
                    VStack(alignment: .leading) {
                        Text(playlist.name)
                        if let count = playlist.trackCount {
                            Text("\(count) tracks")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Playlists")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { newName = ""; showNew = true } label: { Image(systemName: "plus") }
            }
        }
        .alert("New Playlist", isPresented: $showNew) {
            TextField("Name", text: $newName)
            Button("Create") { create() }
            Button("Cancel", role: .cancel) { }
        }
        .onAppear { Task { await reload() } }
        .refreshable { await reload() }
    }

    private func reload() async {
        playlists = (try? await container.library?.playlists()) ?? []
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            _ = try? await container.library?.createPlaylist(name: name, itemIDs: [])
            await reload()
        }
    }
}
