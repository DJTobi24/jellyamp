import SwiftUI
import PhotosUI
import JellyampCore

/// Entry to artists / albums / genres / playlists browsing.
struct LibraryView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink(destination: LikedSongsView()) {
                    Label("Liked Songs", systemImage: "heart.fill")
                }
                NavigationLink(destination: SavedAlbumsView()) {
                    Label("Saved Albums", systemImage: "heart.rectangle")
                }
                NavigationLink(destination: FollowedArtistsView()) {
                    Label("Following", systemImage: "heart.circle")
                }
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

/// Sort options for the albums grid; maps to Jellyfin `sortBy`/`sortOrder`.
enum AlbumSort: String, CaseIterable, Identifiable {
    case name, recentlyAdded, year, artist, random
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: return "Name"
        case .recentlyAdded: return "Recently Added"
        case .year: return "Year"
        case .artist: return "Artist"
        case .random: return "Random"
        }
    }
    var sortBy: String {
        switch self {
        case .name: return "SortName"
        case .recentlyAdded: return "DateCreated"
        case .year: return "ProductionYear"
        case .artist: return "AlbumArtist,SortName"
        case .random: return "Random"
        }
    }
    var sortOrder: String {
        switch self {
        case .recentlyAdded, .year: return "Descending"
        default: return "Ascending"
        }
    }
}

struct AlbumsGridView: View {
    @EnvironmentObject private var container: DependencyContainer
    @State private var albums: [Album] = []
    @State private var isLoading = false
    @State private var reachedEnd = false
    @State private var sort: AlbumSort = .name
    @State private var downloadedOnly = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]
    private let pageSize = 100

    /// Albums to show: the paginated library, or — when filtered — albums
    /// reconstructed from downloaded tracks (fully in memory, no paging).
    private var displayedAlbums: [Album] {
        downloadedOnly ? downloadedAlbums : albums
    }

    private var downloadedAlbums: [Album] {
        var byAlbum: [String: Album] = [:]
        for track in container.downloads?.downloaded ?? [] {
            guard let albumID = track.albumID, byAlbum[albumID] == nil else { continue }
            byAlbum[albumID] = Album(id: albumID, title: track.albumName ?? track.title,
                                     artistName: track.artistName, imageTag: track.imageTag)
        }
        return byAlbum.values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(displayedAlbums) { album in
                    NavigationLink(destination: AlbumDetailView(album: album)) {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                    .albumContextActions(album)
                    .onAppear {
                        // Reached the last loaded card → pull the next page.
                        if !downloadedOnly, album.id == albums.last?.id { Task { await loadMore() } }
                    }
                }
            }
            .padding(.horizontal)
            if isLoading, !downloadedOnly {
                ProgressView().padding()
            }
            if downloadedOnly, displayedAlbums.isEmpty {
                Text("No downloaded albums yet.").foregroundStyle(.secondary).padding()
            }
        }
        .navigationTitle("Albums")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(AlbumSort.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Downloaded only", isOn: $downloadedOnly)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .onChange(of: sort) { _ in Task { await loadMore(reset: true) } }
        .task {
            guard albums.isEmpty else { return }
            // Instant: cached first page, then refresh page 1 from the server.
            if let cached = container.libraryCache?.load([Album].self, for: LibraryCacheKey.allAlbums) {
                albums = cached
            }
            await loadMore(reset: true)
        }
    }

    /// Loads one page; `reset` reloads page 1 (and re-caches it for the default
    /// sort), otherwise it appends the next page. Only the first page is cached,
    /// so launch stays instant without persisting the whole (huge) library.
    private func loadMore(reset: Bool = false) async {
        guard !isLoading, reset || !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        let startIndex = reset ? 0 : albums.count
        guard let page = try? await container.library?.albums(sortBy: sort.sortBy, sortOrder: sort.sortOrder, startIndex: startIndex, limit: pageSize) else { return }
        if reset {
            albums = page
            reachedEnd = page.count < pageSize
            if sort == .name { container.libraryCache?.save(page, for: LibraryCacheKey.allAlbums) }
        } else {
            albums += page
            reachedEnd = page.count < pageSize
        }
    }
}

struct AlbumDetailView: View {
    @EnvironmentObject private var container: DependencyContainer
    let album: Album
    @State private var tracks: [Track] = []
    @State private var searchText = ""

    private var displayed: [Track] { tracks.filtered(by: searchText) }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ArtworkView(itemID: album.id, imageTag: album.imageTag, size: 240)
                    Text(album.title)
                        .font(.title2.bold())
                    Text(album.artistName)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button {
                            play(from: 0)
                        } label: {
                            Label("Play", systemImage: "play.fill")
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            container.player?.playShuffled(tracks)
                        } label: {
                            Label("Shuffle", systemImage: "shuffle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(tracks.isEmpty)
                        FavoriteButton(itemID: album.id, isFavorite: album.isFavorite)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }
            Section {
                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, track in
                    HStack(spacing: 8) {
                        Text("\(track.indexNumber ?? index + 1)")
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                        Text(track.title)
                            .lineLimit(1)
                        Spacer()
                        Text(format(duration: track.duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TrackMenuButton(track: track)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        container.player?.load(queue: PlayQueue(tracks: displayed, startAt: index))
                    }
                    .trackContextActions(track)
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $searchText, prompt: "Search in album")
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
    @State private var isLoading = false
    @State private var reachedEnd = false
    @State private var sortBy = "SortName"   // or "Random"

    private let pageSize = 100

    var body: some View {
        List {
            ForEach(artists) { artist in
                NavigationLink(destination: ArtistDetailView(artist: artist)) {
                    HStack {
                        ArtworkView(itemID: artist.id, imageTag: artist.imageTag, size: 44)
                            .clipShape(Circle())
                        Text(artist.name)
                    }
                }
                .artistContextActions(artist)
                .onAppear {
                    if artist.id == artists.last?.id { Task { await loadMore() } }
                }
            }
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle("Artists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort by", selection: $sortBy) {
                        Text("Name").tag("SortName")
                        Text("Random").tag("Random")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
            }
        }
        .onChange(of: sortBy) { _ in Task { await loadMore(reset: true) } }
        .task {
            guard artists.isEmpty else { return }
            if let cached = container.libraryCache?.load([Artist].self, for: LibraryCacheKey.allArtists) {
                artists = cached
            }
            await loadMore(reset: true)
        }
    }

    private func loadMore(reset: Bool = false) async {
        guard !isLoading, reset || !reachedEnd else { return }
        isLoading = true
        defer { isLoading = false }
        let startIndex = reset ? 0 : artists.count
        guard let page = try? await container.library?.artists(sortBy: sortBy, startIndex: startIndex, limit: pageSize) else { return }
        if reset {
            artists = page
            if sortBy == "SortName" { container.libraryCache?.save(page, for: LibraryCacheKey.allArtists) }
        } else {
            artists += page
        }
        reachedEnd = page.count < pageSize
    }
}

struct ArtistDetailView: View {
    @EnvironmentObject private var container: DependencyContainer
    let artist: Artist
    @State private var detail: Artist?
    @State private var albums: [Album] = []
    @State private var singlesEPs: [Album] = []
    @State private var appearsOn: [Album] = []
    @State private var topTracks: [Track] = []
    @State private var allTracks: [Track] = []
    @State private var similar: [Artist] = []
    @State private var loaded = false
    @State private var searchText = ""

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }
    private var displayed: [Track] { allTracks.filtered(by: searchText) }
    private var bio: String? {
        let text = (detail?.overview ?? artist.overview)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    var body: some View {
        List {
            if isSearching {
                songRows(displayed)
            } else {
                header
                if !topTracks.isEmpty {
                    Section("Popular") { popularRows }
                }
                albumCarousel("Albums", albums)
                albumCarousel("Singles & EPs", singlesEPs)
                albumCarousel("Appears On", appearsOn)
                if !similar.isEmpty {
                    Section("Fans Also Like") { similarRow }
                }
                if let bio {
                    Section("About") {
                        Text(bio).font(.callout).foregroundStyle(.secondary)
                    }
                }
                if loaded, allTracks.isEmpty, albums.isEmpty, singlesEPs.isEmpty {
                    Text("No tracks found for this artist.").foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(artist.name)
        .searchable(text: $searchText, prompt: "Search \(artist.name)")
        .task { await load() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 12) {
            ArtworkView(itemID: artist.id, imageTag: artist.imageTag, size: 160)
                .clipShape(Circle())
            Text(artist.name).font(.title2.bold()).multilineTextAlignment(.center)
            HStack {
                Button {
                    container.player?.load(queue: PlayQueue(tracks: allTracks, startAt: 0))
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(allTracks.isEmpty)
                Button {
                    container.player?.playShuffled(allTracks)
                } label: {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(allTracks.isEmpty)
                FavoriteButton(itemID: artist.id, isFavorite: (detail ?? artist).isFavorite)
            }
        }
        .frame(maxWidth: .infinity)
        .listRowSeparator(.hidden)
    }

    private var popularRows: some View {
        ForEach(Array(topTracks.enumerated()), id: \.element.id) { index, track in
            HStack(spacing: 12) {
                Text("\(index + 1)")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .trailing)
                ArtworkView(itemID: track.albumID ?? track.id, imageTag: track.imageTag, size: 40)
                Text(track.title).lineLimit(1)
                Spacer()
                Text(format(duration: track.duration))
                    .font(.caption).foregroundStyle(.secondary)
                TrackMenuButton(track: track)
            }
            .contentShape(Rectangle())
            .onTapGesture { container.player?.load(queue: PlayQueue(tracks: topTracks, startAt: index)) }
            .trackContextActions(track)
        }
    }

    @ViewBuilder
    private func albumCarousel(_ title: String, _ items: [Album]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(items) { album in
                            NavigationLink(destination: AlbumDetailView(album: album)) {
                                AlbumCard(album: album).frame(width: 150)
                            }
                            .buttonStyle(.plain)
                            .albumContextActions(album)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            }
        }
    }

    private var similarRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(similar) { other in
                    NavigationLink(destination: ArtistDetailView(artist: other)) {
                        VStack {
                            ArtworkView(itemID: other.id, imageTag: other.imageTag, size: 110)
                                .clipShape(Circle())
                            Text(other.name)
                                .font(.caption).lineLimit(1).frame(width: 110)
                        }
                    }
                    .buttonStyle(.plain)
                    .artistContextActions(other)
                }
            }
            .padding(.vertical, 4)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
    }

    private func songRows(_ tracks: [Track]) -> some View {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            HStack(spacing: 8) {
                ArtworkView(itemID: track.albumID ?? track.id, imageTag: track.imageTag, size: 40)
                VStack(alignment: .leading) {
                    Text(track.title).lineLimit(1)
                    Text(track.albumName ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                TrackMenuButton(track: track)
            }
            .contentShape(Rectangle())
            .onTapGesture { container.player?.load(queue: PlayQueue(tracks: tracks, startAt: index)) }
            .trackContextActions(track)
        }
    }

    // MARK: - Loading

    private func load() async {
        guard let library = container.library else { return }
        async let detailF = library.artist(id: artist.id)
        async let topF = library.topTracks(byArtist: artist.id, limit: 5)
        async let albumsF = library.albums(byArtist: artist.id)
        async let appearsF = library.appearsOnAlbums(artistID: artist.id)
        async let tracksF = library.tracks(byArtist: artist.id)
        async let similarF = library.similarArtists(artistID: artist.id, limit: 12)

        detail = try? await detailF
        let everyAlbum = (try? await albumsF) ?? []
        albums = everyAlbum.filter { ($0.trackCount ?? 99) >= 4 }
        singlesEPs = everyAlbum.filter { ($0.trackCount ?? 99) < 4 }
        appearsOn = (try? await appearsF) ?? []
        topTracks = (try? await topF) ?? []
        allTracks = (try? await tracksF) ?? []
        similar = (try? await similarF) ?? []
        loaded = true
    }

    private func format(duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct LikedSongsView: View {
    @EnvironmentObject private var container: DependencyContainer
    @State private var tracks: [Track] = []
    @State private var loaded = false
    @State private var searchText = ""

    var body: some View {
        TrackListContent(
            tracks: tracks.filtered(by: searchText),
            isLoaded: loaded,
            emptyMessage: "No liked songs yet — tap the heart on a track to add it."
        )
        .listStyle(.plain)
        .navigationTitle("Liked Songs")
        .searchable(text: $searchText, prompt: "Search liked songs")
        .task {
            tracks = (try? await container.library?.favoriteTracks(limit: 500)) ?? []
            loaded = true
        }
    }
}

struct SavedAlbumsView: View {
    @EnvironmentObject private var container: DependencyContainer
    @State private var albums: [Album] = []
    @State private var loaded = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        Group {
            if loaded, albums.isEmpty {
                ContentUnavailableCompatView(
                    title: "No Saved Albums",
                    systemImage: "heart",
                    description: "Tap the heart on an album to save it here."
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(albums) { album in
                            NavigationLink(destination: AlbumDetailView(album: album)) {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(.plain)
                            .albumContextActions(album)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .navigationTitle("Saved Albums")
        .task {
            albums = (try? await container.library?.favoriteAlbums(limit: 500)) ?? []
            loaded = true
        }
    }
}

struct FollowedArtistsView: View {
    @EnvironmentObject private var container: DependencyContainer
    @State private var artists: [Artist] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded, artists.isEmpty {
                ContentUnavailableCompatView(
                    title: "Not Following Anyone",
                    systemImage: "heart",
                    description: "Tap the heart on an artist to follow them."
                )
            } else {
                List(artists) { artist in
                    NavigationLink(destination: ArtistDetailView(artist: artist)) {
                        HStack {
                            ArtworkView(itemID: artist.id, imageTag: artist.imageTag, size: 44)
                                .clipShape(Circle())
                            Text(artist.name)
                        }
                    }
                    .artistContextActions(artist)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Following")
        .task {
            artists = (try? await container.library?.favoriteArtists(limit: 500)) ?? []
            loaded = true
        }
    }
}

struct GenresView: View {
    @EnvironmentObject private var container: DependencyContainer
    @State private var genres: [Genre] = []

    var body: some View {
        List(genres) { genre in
            NavigationLink(destination: GenreDetailView(genre: genre)) {
                Text(genre.name)
            }
        }
        .navigationTitle("Genres")
        .task {
            genres = (try? await container.library?.genres()) ?? []
        }
    }
}

struct GenreDetailView: View {
    @EnvironmentObject private var container: DependencyContainer
    let genre: Genre
    @State private var tracks: [Track] = []
    @State private var loaded = false
    @State private var searchText = ""

    private var displayed: [Track] { tracks.filtered(by: searchText) }

    var body: some View {
        TrackListContent(
            tracks: displayed,
            isLoaded: loaded,
            emptyMessage: "No tracks in this genre."
        )
        .listStyle(.plain)
        .navigationTitle(genre.name)
        .searchable(text: $searchText, prompt: "Search in \(genre.name)")
        .task {
            tracks = (try? await container.library?.tracks(inGenre: genre.id)) ?? []
            loaded = true
        }
    }
}

/// Shared track list with Play/Shuffle header, tap-to-play, ⋯ and context
/// actions — used by genre / playlist / liked / artist detail views.
struct TrackListContent: View {
    @EnvironmentObject private var container: DependencyContainer
    let tracks: [Track]
    var isLoaded: Bool = true
    var emptyMessage: String = "No tracks."

    var body: some View {
        List {
            if !tracks.isEmpty {
                HStack {
                    Button {
                        container.player?.load(queue: PlayQueue(tracks: tracks, startAt: 0))
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        container.player?.playShuffled(tracks)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    CollectionMenuButton(tracks: tracks)
                }
                .listRowSeparator(.hidden)
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
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
                    container.player?.load(queue: PlayQueue(tracks: tracks, startAt: index))
                }
                .trackContextActions(track)
            }
            if isLoaded, tracks.isEmpty {
                Text(emptyMessage).foregroundStyle(.secondary)
            }
        }
    }
}

extension Array where Element == Track {
    /// Case-insensitive filter over title + artist; empty query keeps all.
    func filtered(by query: String) -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return self }
        return filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.artistName.localizedCaseInsensitiveContains(trimmed)
        }
    }
}

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
