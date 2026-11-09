import SwiftUI
import JellyampCore

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
