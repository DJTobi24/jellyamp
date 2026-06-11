import SwiftUI
import JellyampCore

/// Entry to artists / albums / genres / playlists browsing.
struct LibraryView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink(destination: AlbumsGridView()) {
                    Label("Albums", systemImage: "square.stack")
                }
                NavigationLink(destination: ArtistsView()) {
                    Label("Artists", systemImage: "music.mic")
                }
                NavigationLink(destination: GenresView()) {
                    Label("Genres", systemImage: "guitars")
                }
                NavigationLink(destination: PlaylistsView()) {
                    Label("Playlists", systemImage: "music.note.list")
                }
            }
            .navigationTitle("Library")
        }
    }
}

struct AlbumsGridView: View {
    @EnvironmentObject private var container: DependencyContainer
    @State private var albums: [Album] = []

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(albums) { album in
                    NavigationLink(destination: AlbumDetailView(album: album)) {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .navigationTitle("Albums")
        .task {
            albums = (try? await container.library?.albums(sortBy: "SortName", startIndex: 0, limit: 200)) ?? []
        }
    }
}

struct AlbumDetailView: View {
    @EnvironmentObject private var container: DependencyContainer
    let album: Album
    @State private var tracks: [Track] = []

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ArtworkView(itemID: album.id, imageTag: album.imageTag, size: 240)
                    Text(album.title)
                        .font(.title2.bold())
                    Text(album.artistName)
                        .foregroundStyle(.secondary)
                    Button {
                        play(from: 0)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }
            Section {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    HStack(spacing: 8) {
                        Button {
                            play(from: index)
                        } label: {
                            HStack {
                                Text("\(track.indexNumber ?? index + 1)")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, alignment: .trailing)
                                Text(track.title)
                                    .lineLimit(1)
                                Spacer()
                                Text(format(duration: track.duration))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        TrackMenuButton(track: track)
                    }
                    .trackContextActions(track)
                }
            }
        }
        .listStyle(.plain)
        .task {
            tracks = (try? await container.library?.tracks(inAlbum: album.id)) ?? []
        }
    }

    private func play(from index: Int) {
        container.player?.load(queue: PlayQueue(tracks: tracks, startAt: index))
    }

    private func format(duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct ArtistsView: View {
    @EnvironmentObject private var container: DependencyContainer
    @State private var artists: [Artist] = []

    var body: some View {
        List(artists) { artist in
            NavigationLink(destination: ArtistDetailView(artist: artist)) {
                HStack {
                    ArtworkView(itemID: artist.id, imageTag: artist.imageTag, size: 44)
                        .clipShape(Circle())
                    Text(artist.name)
                }
            }
        }
        .navigationTitle("Artists")
        .task {
            artists = (try? await container.library?.artists(startIndex: 0, limit: 500)) ?? []
        }
    }
}

struct ArtistDetailView: View {
    @EnvironmentObject private var container: DependencyContainer
    let artist: Artist
    @State private var albums: [Album] = []
    @State private var tracks: [Track] = []
    @State private var loaded = false

    var body: some View {
        List {
            if !albums.isEmpty {
                Section("Albums") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(albums) { album in
                                NavigationLink(destination: AlbumDetailView(album: album)) {
                                    AlbumCard(album: album).frame(width: 150)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                }
            }
            if !tracks.isEmpty {
                Section("Songs") {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        HStack(spacing: 8) {
                            Button {
                                container.player?.load(queue: PlayQueue(tracks: tracks, startAt: index))
                            } label: {
                                HStack {
                                    Text(track.title).lineLimit(1)
                                    Spacer()
                                    Text(format(duration: track.duration))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            TrackMenuButton(track: track)
                        }
                        .trackContextActions(track)
                    }
                }
            }
            if loaded, albums.isEmpty, tracks.isEmpty {
                Text("No tracks found for this artist.")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
        .navigationTitle(artist.name)
        .task {
            guard let library = container.library else { return }
            albums = (try? await library.albums(byArtist: artist.id)) ?? []
            tracks = (try? await library.tracks(byArtist: artist.id)) ?? []
            loaded = true
        }
    }

    private func format(duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct GenresView: View {
    @EnvironmentObject private var container: DependencyContainer
    @State private var genres: [Genre] = []

    var body: some View {
        List(genres) { genre in
            Text(genre.name)
        }
        .navigationTitle("Genres")
        .task {
            genres = (try? await container.library?.genres()) ?? []
        }
    }
}

struct PlaylistsView: View {
    @EnvironmentObject private var container: DependencyContainer
    @State private var playlists: [Playlist] = []

    var body: some View {
        List(playlists) { playlist in
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
        .navigationTitle("Playlists")
        .task {
            playlists = (try? await container.library?.playlists()) ?? []
        }
    }
}
