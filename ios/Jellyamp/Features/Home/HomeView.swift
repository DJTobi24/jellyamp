import SwiftUI
import JellyampCore
import JellyfinBackend

/// Landing screen in Plexamp spirit: Mixes for You and Sonic Adventure when
/// the sonic provider offers them, stations (which also work against plain
/// Jellyfin), and the recently played / added / favorite shelves.
///
/// Content comes from `HomeViewModel`: cached shelves paint immediately and
/// every shelf refreshes on its own, so one failing request never empties
/// the screen.
struct HomeView: View {
    @EnvironmentObject private var container: DependencyContainer
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var model = HomeViewModel()

    private var metrics: HomeMetrics {
        HomeMetrics(isWide: horizontalSizeClass == .regular)
    }

    private var supportsMixes: Bool {
        container.sonicCapabilities.supports(.mixes)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.vertical, 12)
            }
            .navigationTitle(greetingTitle)
            .task { await model.loadIfNeeded(container: container) }
            .task(id: supportsMixes) {
                // The sonic server is probed after launch; fetch the mixes
                // once it turns out to be there. The regular refresh covers
                // the first load.
                if model.hasFinishedRefresh {
                    await model.refreshMixes(container: container)
                }
            }
            .refreshable { await model.refresh(container: container) }
        }
    }

    private var greetingTitle: LocalizedStringKey {
        switch HomeGreeting.bucket(for: Date()) {
        case .morning: return "Good Morning"
        case .afternoon: return "Good Afternoon"
        case .evening: return "Good Evening"
        case .night: return "Late Night Listening"
        }
    }

    // MARK: - States

    @ViewBuilder
    private var content: some View {
        switch model.contentState {
        case .loadingFirstTime:
            HomeSkeleton(metrics: metrics)
        case .content:
            shelves
        case .emptyLibrary:
            ContentUnavailableCompatView(
                title: "Your Library Is Empty",
                systemImage: "music.note.house",
                description: "Add music to your Jellyfin server and it will show up here. Pull down to refresh."
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        case .unreachable:
            VStack(spacing: 8) {
                ContentUnavailableCompatView(
                    title: "Can't Reach Your Server",
                    systemImage: "wifi.exclamationmark",
                    description: "Home could not be loaded. Check your connection and try again."
                )
                Button("Try Again") {
                    Task { await model.refresh(container: container) }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
        }
    }

    private var shelves: some View {
        VStack(alignment: .leading, spacing: 28) {
            if supportsMixes, !model.mixes.isEmpty {
                mixesShelf
            }
            if container.sonicCapabilities.supports(.adventure) {
                adventureBanner
            }
            if hasStations {
                HomeStationShelves(
                    stations: container.stations,
                    shelves: model.stationShelves,
                    metrics: metrics
                )
            }
            if !model.jumpBackIn.isEmpty {
                albumShelf("Jump Back In", albums: model.jumpBackIn)
            }
            if !model.recentTracks.isEmpty {
                recentlyPlayedShelf
            }
            if !model.recentAlbums.isEmpty {
                albumShelf("Recently Added", albums: model.recentAlbums)
            }
            if !model.favoriteAlbums.isEmpty {
                albumShelf("Favorite Albums", albums: model.favoriteAlbums)
            }
        }
    }

    private var hasStations: Bool {
        let shelves = model.stationShelves
        return !shelves.stations.isEmpty || !shelves.timeTravel.isEmpty
    }

    // MARK: - Shelves

    private var mixesShelf: some View {
        HomeShelf("Mixes for You", inset: metrics.inset) {
            ForEach(model.mixes) { mix in
                NavigationLink(destination: MixDetailView(mix: mix)) {
                    MixCard(mix: mix, size: metrics.cardSize)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button {
                        play(mix: mix, shuffled: false)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    Button {
                        play(mix: mix, shuffled: true)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                }
            }
        }
    }

    private var adventureBanner: some View {
        NavigationLink(destination: SonicAdventureView()) {
            HStack(spacing: 14) {
                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sonic Adventure")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Travel from one track to another through your library.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(14)
            .background(
                LinearGradient(colors: [.indigo, .purple], startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 14)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 640, alignment: .leading)
        .padding(.horizontal, metrics.inset)
    }

    private func albumShelf(_ title: LocalizedStringKey, albums: [Album]) -> some View {
        HomeShelf(title, inset: metrics.inset) {
            ForEach(albums) { album in
                NavigationLink(destination: AlbumDetailView(album: album)) {
                    AlbumCard(album: album, size: metrics.cardSize)
                }
                .buttonStyle(.plain)
                .albumContextActions(album)
            }
        }
    }

    private var recentlyPlayedShelf: some View {
        HomeShelf("Recently Played", inset: metrics.inset) {
            ForEach(Array(model.recentTracks.enumerated()), id: \.element.id) { index, track in
                Button {
                    container.player?.load(queue: PlayQueue(tracks: model.recentTracks, startAt: index))
                } label: {
                    TrackCard(track: track, size: metrics.trackCardSize)
                }
                .buttonStyle(.plain)
                .trackContextActions(track)
            }
        }
    }

    private func play(mix: MixDescriptor, shuffled: Bool) {
        Task {
            guard let resolver = container.trackResolver,
                  let tracks = try? await resolver.tracks(byIDs: mix.itemIDs), !tracks.isEmpty else { return }
            if shuffled {
                container.player?.playShuffled(tracks)
            } else {
                container.player?.load(queue: PlayQueue(tracks: tracks))
            }
        }
    }
}

struct AlbumCard: View {
    let album: Album
    var size: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading) {
            ArtworkView(itemID: album.id, imageTag: album.imageTag, size: size)
            Text(album.title)
                .font(.callout)
                .lineLimit(1)
            Text(album.artistName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: size)
    }
}

struct TrackCard: View {
    let track: Track
    var size: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading) {
            ArtworkView(itemID: track.albumID ?? track.id, imageTag: track.imageTag, size: size)
            Text(track.title)
                .font(.callout)
                .lineLimit(1)
            Text(track.artistName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: size)
    }
}

struct MixCard: View {
    let mix: MixDescriptor
    var size: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
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
        .frame(width: size)
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
        // Covers of downloaded music are on disk; use them first so artwork
        // shows offline (and costs no request online).
        if let local = DownloadArtworkStore.localURL(itemID: itemID) { return local }
        guard let session = container.session else { return nil }
        return ImageURLBuilder.url(
            itemID: itemID,
            tag: imageTag,
            maxWidth: Int(size * 3),
            session: session
        )
    }
}
