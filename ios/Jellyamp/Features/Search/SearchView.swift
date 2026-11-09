import SwiftUI
import JellyampCore

struct SearchView: View {
    @EnvironmentObject private var container: DependencyContainer
    @State private var query = ""
    @State private var tracks: [Track] = []
    @State private var albums: [Album] = []
    @State private var artists: [Artist] = []
    @State private var playlists: [Playlist] = []
    @State private var genres: [Genre] = []
    @State private var recents: [String] = RecentSearches.load()

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Group {
                if isSearching {
                    results
                } else {
                    browse
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Artists, albums, songs, playlists")
            .onSubmit(of: .search) { record(query) }
            .task(id: query) { await runSearch() }
            .task {
                if genres.isEmpty { genres = (try? await container.library?.genres()) ?? [] }
            }
        }
    }

    // MARK: - Results

    private var results: some View {
        List {
            if !artists.isEmpty {
                Section("Artists") {
                    ForEach(artists) { artist in
                        NavigationLink(destination: ArtistDetailView(artist: artist)) {
                            HStack {
                                ArtworkView(itemID: artist.id, imageTag: artist.imageTag, size: 44)
                                    .clipShape(Circle())
                                Text(artist.name)
                            }
                        }
                        .artistContextActions(artist)
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
                        .albumContextActions(album)
                    }
                }
            }
            if !playlists.isEmpty {
                Section("Playlists") {
                    ForEach(playlists) { playlist in
                        NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                            HStack {
                                ArtworkView(itemID: playlist.id, imageTag: playlist.imageTag, size: 44)
                                VStack(alignment: .leading) {
                                    Text(playlist.name)
                                    if let count = playlist.trackCount {
                                        Text("\(count) songs")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if !tracks.isEmpty {
                Section("Songs") {
                    ForEach(tracks) { track in
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
                            TrackMenuButton(track: track)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            record(query)
                            container.player?.load(queue: PlayQueue(tracks: [track]))
                        }
                        .trackContextActions(track)
                    }
                }
            }
        }
    }

    // MARK: - Browse (empty query)

    private var browse: some View {
        List {
            if !recents.isEmpty {
                Section {
                    ForEach(recents, id: \.self) { term in
                        Button {
                            query = term
                        } label: {
                            Label(term, systemImage: "clock.arrow.circlepath")
                                .foregroundStyle(.primary)
                        }
                    }
                    .onDelete { offsets in
                        recents.remove(atOffsets: offsets)
                        RecentSearches.save(recents)
                    }
                } header: {
                    HStack {
                        Text("Recent searches")
                        Spacer()
                        Button("Clear") {
                            recents = []
                            RecentSearches.save([])
                        }
                        .font(.caption)
                    }
                }
            }
            if !genres.isEmpty {
                Section("Browse") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(genres) { genre in
                            NavigationLink(destination: GenreDetailView(genre: genre)) {
                                GenreTile(name: genre.name)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
            }
        }
    }

    // MARK: - Logic

    private func runSearch() async {
        guard isSearching, let library = container.library else {
            tracks = []; albums = []; artists = []; playlists = []
            return
        }
        try? await Task.sleep(nanoseconds: 250_000_000)   // debounce
        guard !Task.isCancelled else { return }
        if let results = try? await library.search(query: query, limit: 20) {
            tracks = results.tracks
            albums = results.albums
            artists = results.artists
            playlists = results.playlists
        }
    }

    private func record(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return }
        recents.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        recents.insert(trimmed, at: 0)
        if recents.count > 10 { recents = Array(recents.prefix(10)) }
        RecentSearches.save(recents)
    }
}

/// Colored genre tile for the browse grid. The hue is derived from the name so
/// each genre keeps a stable color.
struct GenreTile: View {
    let name: String

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [color, color.opacity(0.6)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(name)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(10)
        }
        .frame(height: 80)
    }

    private var color: Color {
        let hue = Double(abs(name.hashValue) % 360) / 360
        return Color(hue: hue, saturation: 0.55, brightness: 0.65)
    }
}

/// Last few search terms, persisted in UserDefaults.
enum RecentSearches {
    private static let key = "jellyamp.recentSearches"
    static func load() -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func save(_ terms: [String]) { UserDefaults.standard.set(terms, forKey: key) }
}
