import SwiftUI
import JellyampCore

/// Presented as a sheet (from a track's ⋯ menu) to add the track to an
/// existing playlist or a new one.
struct AddToPlaylistView: View {
    @EnvironmentObject private var container: DependencyContainer
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var playlists: [Playlist] = []
    @State private var newName = ""
    @State private var showNewPlaylist = false
    @State private var working = false

    var body: some View {
        NavigationStack {
            List {
                Button {
                    showNewPlaylist = true
                } label: {
                    Label("New Playlist", systemImage: "plus")
                }
                if !playlists.isEmpty {
                    Section("Playlists") {
                        ForEach(playlists) { playlist in
                            Button {
                                add(to: playlist.id)
                            } label: {
                                HStack {
                                    ArtworkView(itemID: playlist.id, imageTag: playlist.imageTag, size: 40)
                                    Text(playlist.name).lineLimit(1)
                                    Spacer()
                                    if let count = playlist.trackCount {
                                        Text("\(count)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .disabled(working)
            .task {
                playlists = (try? await container.library?.playlists()) ?? []
            }
            .alert("New Playlist", isPresented: $showNewPlaylist) {
                TextField("Name", text: $newName)
                Button("Create") { createAndAdd() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Create a playlist with \u{201C}\(track.title)\u{201D}.")
            }
        }
    }

    private func add(to playlistID: String) {
        working = true
        Task { @MainActor in
            try? await container.library?.addToPlaylist(playlistID: playlistID, itemIDs: [track.id])
            dismiss()
        }
    }

    private func createAndAdd() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        working = true
        Task { @MainActor in
            _ = try? await container.library?.createPlaylist(name: name, itemIDs: [track.id])
            dismiss()
        }
    }
}
