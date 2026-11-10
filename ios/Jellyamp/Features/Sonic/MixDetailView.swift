import SwiftUI
import JellyampCore
import JellyfinBackend

/// A generated mix ("Mixes for You"): its tracks in the house track-list
/// style with Play / Shuffle, plus "Save as Playlist".
struct MixDetailView: View {
    @EnvironmentObject private var container: DependencyContainer
    let mix: MixDescriptor
    @State private var tracks: [Track] = []
    @State private var isLoaded = false
    @State private var showSavePrompt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let description = mix.description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
            TrackListContent(
                tracks: tracks,
                isLoaded: isLoaded,
                emptyMessage: String(localized: "The tracks of this mix are no longer in your library.")
            )
            .listStyle(.plain)
            .overlay {
                if !isLoaded { ProgressView() }
            }
        }
        .navigationTitle(mix.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showSavePrompt = true
                } label: {
                    Label("Save as Playlist", systemImage: "text.badge.plus")
                }
                .disabled(tracks.isEmpty)
            }
        }
        .saveAsPlaylistPrompt(isPresented: $showSavePrompt, tracks: tracks, suggestedName: mix.title)
        .task { await load() }
    }

    private func load() async {
        guard !isLoaded else { return }
        guard let resolver = container.trackResolver else { return }
        if let resolved = try? await resolver.tracks(byIDs: mix.itemIDs) {
            tracks = HomeShelves.uniqued(resolved)
        }
        isLoaded = true
    }
}

extension View {
    /// Asks for a name and saves `tracks` as a new Jellyfin playlist, then
    /// confirms (or reports the failure). Attach to the screen and flip
    /// `isPresented` from a button — alerts hung on toolbar items are
    /// unreliable.
    func saveAsPlaylistPrompt(isPresented: Binding<Bool>, tracks: [Track], suggestedName: String) -> some View {
        modifier(SaveAsPlaylistPrompt(isPresented: isPresented, tracks: tracks, suggestedName: suggestedName))
    }
}

private struct SaveAsPlaylistPrompt: ViewModifier {
    @EnvironmentObject private var container: DependencyContainer
    @Binding var isPresented: Bool
    let tracks: [Track]
    let suggestedName: String

    @State private var name = ""
    @State private var resultMessage: String?
    @State private var showResult = false

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { presented in
                if presented { name = suggestedName }
            }
            .alert("Save as Playlist", isPresented: $isPresented) {
                TextField("Name", text: $name)
                Button("Save") { save() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Creates a playlist with \(tracks.count) tracks on your Jellyfin server.")
            }
            .alert("Playlist", isPresented: $showResult) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(resultMessage ?? "")
            }
    }

    @MainActor
    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlistName = trimmed.isEmpty ? suggestedName : trimmed
        let ids = tracks.map(\.id)
        guard !ids.isEmpty, let library = container.library else { return }
        Task { @MainActor in
            do {
                try await PlaylistSaver.save(name: playlistName, trackIDs: ids, library: library)
                resultMessage = String(localized: "Saved \u{201C}\(playlistName)\u{201D} to your playlists.")
            } catch {
                resultMessage = String(localized: "The playlist could not be saved. Check your connection and try again.")
            }
            showResult = true
        }
    }
}

enum PlaylistSaver {
    /// Jellyfin takes the playlist's items in the query string, so long lists
    /// are created with a first chunk and extended with the rest.
    static func save(name: String, trackIDs: [String], library: MusicLibraryProviding) async throws {
        let chunkSize = 80
        let first = Array(trackIDs.prefix(chunkSize))
        let playlistID = try await library.createPlaylist(name: name, itemIDs: first)
        var start = chunkSize
        while start < trackIDs.count {
            let end = min(start + chunkSize, trackIDs.count)
            try await library.addToPlaylist(playlistID: playlistID, itemIDs: Array(trackIDs[start..<end]))
            start = end
        }
    }
}
