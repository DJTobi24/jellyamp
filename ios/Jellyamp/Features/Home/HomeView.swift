import SwiftUI
import JellyampCore
import JellyfinBackend

/// Landing screen: recently added/played shelves; the Mixes-for-You shelf
/// appears when the sonic provider reports the `mixes` capability.
struct HomeView: View {
    @EnvironmentObject private var container: DependencyContainer
    @State private var recentAlbums: [Album] = []
    @State private var recentTracks: [Track] = []
    @State private var mixes: [MixDescriptor] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !mixes.isEmpty {
                        shelf(title: "Mixes for You") {
                            ForEach(mixes) { mix in
                                MixCard(mix: mix)
                            }
                        }
                    }
                    shelf(title: "Recently Added") {
                        ForEach(recentAlbums) { album in
                            AlbumCard(album: album)
                        }
                    }
                    shelf(title: "Recently Played") {
                        ForEach(recentTracks) { track in
                            TrackCard(track: track)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .navigationTitle("Home")
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func shelf<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12, content: content)
            }
        }
    }

    private func load() async {
        guard let library = container.library else { return }
        recentAlbums = (try? await library.recentlyAddedAlbums(limit: 20)) ?? []
        recentTracks = (try? await library.recentlyPlayedTracks(limit: 20)) ?? []
        if container.sonicCapabilities.supports(.mixes),
           let sonic = container.sonic,
           let userID = container.session?.userID {
            mixes = (try? await sonic.mixes(forUser: userID)) ?? []
        }
    }
}

struct AlbumCard: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading) {
            ArtworkView(itemID: album.id, imageTag: album.imageTag, size: 150)
            Text(album.title)
                .font(.callout)
                .lineLimit(1)
            Text(album.artistName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 150)
    }
}

struct TrackCard: View {
    let track: Track

    var body: some View {
        VStack(alignment: .leading) {
            ArtworkView(itemID: track.albumID ?? track.id, imageTag: track.imageTag, size: 120)
            Text(track.title)
                .font(.callout)
                .lineLimit(1)
            Text(track.artistName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 120)
    }
}

struct MixCard: View {
    let mix: MixDescriptor

    var body: some View {
        VStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 150, height: 150)
                .overlay {
                    Image(systemName: "waveform")
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                }
            Text(mix.title)
                .font(.callout)
                .lineLimit(1)
            if let description = mix.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(width: 150)
    }
}

/// Async album/artist artwork with blurhash-style placeholder (Phase 1).
struct ArtworkView: View {
    @EnvironmentObject private var container: DependencyContainer
    let itemID: String
    let imageTag: String?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: imageURL) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var imageURL: URL? {
        guard let session = container.session else { return nil }
        return ImageURLBuilder.url(
            itemID: itemID,
            tag: imageTag,
            maxWidth: Int(size * 3),
            session: session
        )
    }
}
