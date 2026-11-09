import SwiftUI
import PhotosUI
import JellyampCore

struct PlaylistDetailView: View {
    @EnvironmentObject private var container: DependencyContainer
    @Environment(\.dismiss) private var dismiss
    let playlist: Playlist
    @State private var tracks: [Track] = []
    @State private var searchText = ""
    @State private var name: String
    @State private var artworkVersion = 0
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDelete = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false

    init(playlist: Playlist) {
        self.playlist = playlist
        _name = State(initialValue: playlist.name)
    }

    private var displayed: [Track] { tracks.filtered(by: searchText) }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ArtworkView(itemID: playlist.id, imageTag: playlist.imageTag, size: 240)
                        .id(artworkVersion)
                    Text(name)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    HStack {
                        Button {
                            container.player?.load(queue: PlayQueue(tracks: tracks, startAt: 0))
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(tracks.isEmpty)
                        Button {
                            container.player?.playShuffled(tracks)
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(tracks.isEmpty)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }
            Section {
                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, track in
                    HStack(spacing: 8) {
                        ArtworkView(itemID: track.albumID ?? track.id, imageTag: track.imageTag, size: 40)
                        VStack(alignment: .leading) {
                            Text(track.title).lineLimit(1)
                            Text(track.artistName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        TrackMenuButton(track: track)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        container.player?.load(queue: PlayQueue(tracks: displayed, startAt: index))
                    }
                    .trackContextActions(track)
                }
                .onDelete(perform: removeTracks)
                .onMove(perform: searchText.isEmpty ? moveTrack : nil)
            }
        }
        .listStyle(.plain)
        .navigationTitle(name)
        .searchable(text: $searchText, prompt: "Search in playlist")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { renameText = name; showRename = true } label: { Label("Rename", systemImage: "pencil") }
                    Button { showPhotoPicker = true } label: { Label("Change Image", systemImage: "photo") }
                    Button(role: .destructive) { showDelete = true } label: { Label("Delete Playlist", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
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
        .task { await reload() }
    }

    private func reload() async {
        tracks = (try? await container.library?.tracks(inPlaylist: playlist.id)) ?? []
    }

    private func removeTracks(at offsets: IndexSet) {
        let entryIDs = offsets.compactMap { displayed[$0].playlistEntryID }
        guard !entryIDs.isEmpty else { return }
        Task {
            try? await container.library?.removeFromPlaylist(playlistID: playlist.id, entryIDs: entryIDs)
            await reload()
        }
    }

    private func moveTrack(from source: IndexSet, to destination: Int) {
        guard let from = source.first, let entry = tracks[safe: from]?.playlistEntryID else { return }
        let target = destination > from ? destination - 1 : destination
        Task {
            try? await container.library?.movePlaylistItem(playlistID: playlist.id, entryID: entry, toIndex: target)
            await reload()
        }
    }

    private func rename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        name = trimmed
        Task { try? await container.library?.renamePlaylist(playlistID: playlist.id, name: trimmed) }
    }

    private func deletePlaylist() {
        Task {
            try? await container.library?.deletePlaylist(playlistID: playlist.id)
            dismiss()
        }
    }

    private func uploadImageIfNeeded() async {
        guard let photoItem,
              let data = try? await photoItem.loadTransferable(type: Data.self),
              let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) else { return }
        try? await container.library?.setPlaylistImage(playlistID: playlist.id, jpeg: jpeg)
        artworkVersion += 1
        self.photoItem = nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
