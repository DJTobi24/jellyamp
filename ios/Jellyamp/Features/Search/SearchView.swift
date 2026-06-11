import SwiftUI
import JellyampCore

struct SearchView: View {
    @EnvironmentObject private var container: DependencyContainer
    @State private var query = ""
    @State private var tracks: [Track] = []
    @State private var albums: [Album] = []
    @State private var artists: [Artist] = []

    var body: some View {
        NavigationStack {
            List {
                if !artists.isEmpty {
                    Section("Artists") {
                        ForEach(artists) { artist in
                            NavigationLink(destination: ArtistDetailView(artist: artist)) {
                                Text(artist.name)
                            }
                        }
                    }
                }
                if !albums.isEmpty {
                    Section("Albums") {
                        ForEach(albums) { album in
                            NavigationLink(destination: AlbumDetailView(album: album)) {
                                HStack {
                                    ArtworkView(itemID: album.id, imageTag: album.imageTag, size: 44)
                                    VStack(alignment: .leading) {
                                        Text(album.title)
                                        Text(album.artistName)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                if !tracks.isEmpty {
                    Section("Tracks") {
                        ForEach(tracks) { track in
                            HStack(spacing: 12) {
                                Button {
                                    container.player?.load(queue: PlayQueue(tracks: [track]))
                                } label: {
                                    HStack(spacing: 12) {
                                        ArtworkView(itemID: track.albumID ?? track.id, imageTag: track.imageTag, size: 44)
                                        VStack(alignment: .leading) {
                                            Text(track.title).lineLimit(1)
                                            Text(track.artistName)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
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
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Artists, albums, songs")
            .task(id: query) {
                guard query.count >= 2, let library = container.library else {
                    tracks = []
                    albums = []
                    artists = []
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                if let results = try? await library.search(query: query, limit: 20) {
                    tracks = results.tracks
                    albums = results.albums
                    artists = results.artists
                }
            }
        }
    }
}
