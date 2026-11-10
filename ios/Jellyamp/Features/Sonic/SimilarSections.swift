import SwiftUI
import JellyampCore
import JellyfinBackend
import SonicClient

/// How a similar-items section presents itself in its host.
enum SimilarSectionStyle {
    /// A titled shelf for `ScrollView`/`VStack` hosts (Now Playing).
    case shelf
    /// A `Section` with a carousel row, for `List` hosts (album and artist
    /// detail screens).
    case listSection
}

/// "Sonically Similar" tracks for a track: self-loading, renders nothing when
/// the provider has no similarity or nothing comes back. Tapping a card plays
/// the similar tracks starting there.
///
///     SimilarTracksSection(trackID: track.id)
struct SimilarTracksSection: View {
    @EnvironmentObject private var container: DependencyContainer
    let trackID: String
    /// Drop results from this album (pass the seed track's album so the
    /// section doesn't repeat the album on screen).
    var excludingAlbumID: String? = nil
    var style: SimilarSectionStyle = .shelf
    var limit: Int = 20

    var body: some View {
        SimilarItemsSection(
            seedID: trackID,
            title: container.isSonicServerActive ? "Sonically Similar" : "More Like This",
            style: style,
            placeholderIsRound: false,
            load: { container in
                await SimilarLoader.tracks(similarTo: trackID, excludingAlbumID: excludingAlbumID, limit: limit, container: container)
            },
            card: { tracks, index in
                Button {
                    container.player?.load(queue: PlayQueue(tracks: tracks, startAt: index))
                } label: {
                    TrackCard(track: tracks[index])
                }
                .buttonStyle(.plain)
                .trackContextActions(tracks[index])
            }
        )
    }
}

/// Sonically similar albums for an album. Cards are `RouteLink`s, so they
/// work in the routed stacks (Library, Search) and in plain ones (Home).
///
///     SimilarAlbumsSection(albumID: album.id, style: .listSection)
struct SimilarAlbumsSection: View {
    @EnvironmentObject private var container: DependencyContainer
    let albumID: String
    var style: SimilarSectionStyle = .shelf
    var limit: Int = 12

    var body: some View {
        SimilarItemsSection(
            seedID: albumID,
            title: container.isSonicServerActive ? "Sonically Similar Albums" : "Similar Albums",
            style: style,
            placeholderIsRound: false,
            load: { container in
                await SimilarLoader.albums(similarTo: albumID, limit: limit, container: container)
            },
            card: { albums, index in
                RouteLink(.album(albums[index])) {
                    AlbumCard(album: albums[index])
                }
                .buttonStyle(.plain)
                .albumContextActions(albums[index])
            }
        )
    }
}

// MARK: - Shared machinery

/// Loads the items for one seed and lays them out as a carousel. While
/// loading it shows a short skeleton row (a `List` needs a real row to hang
/// the load on); afterwards it shows the carousel or nothing at all.
private struct SimilarItemsSection<Item: Identifiable, Card: View>: View where Item.ID == String {
    @EnvironmentObject private var container: DependencyContainer
    let seedID: String
    let title: LocalizedStringKey
    let style: SimilarSectionStyle
    let placeholderIsRound: Bool
    let load: (DependencyContainer) async -> [Item]
    let card: ([Item], Int) -> Card

    @State private var items: [Item] = []
    /// The `loadKey` the current `items` belong to; nil until the first load.
    @State private var loadedKey: String?

    /// Reload when the seed changes (Now Playing moves on) or the provider
    /// is re-wired (server connected / lost).
    private var loadKey: String {
        "\(seedID)|\(container.isSonicServerActive)"
    }

    var body: some View {
        if container.sonicCapabilities.supports(.similar) {
            if loadedKey == loadKey {
                if !items.isEmpty {
                    present(carousel)
                }
            } else {
                // The load hangs on the row itself, not on the `Section`: a
                // modifier on a section is applied to each of its parts.
                present(placeholder.task(id: loadKey) { await reload() })
            }
        }
    }

    private func reload() async {
        let key = loadKey
        let loaded = await load(container)
        guard !Task.isCancelled else { return }
        items = loaded
        loadedKey = key
    }

    @ViewBuilder
    private func present<Row: View>(_ row: Row) -> some View {
        switch style {
        case .shelf:
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.title3.bold())
                    .padding(.horizontal)
                    .accessibilityAddTraits(.isHeader)
                row
            }
        case .listSection:
            Section {
                row.listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            } header: {
                Text(title)
            }
        }
    }

    private var carousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(items.indices), id: \.self) { index in
                    card(items, index)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }

    private var placeholder: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(0..<4, id: \.self) { _ in
                if placeholderIsRound {
                    Circle().fill(.quaternary).frame(width: 110, height: 110)
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: 120, height: 120)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityHidden(true)
    }
}

/// Fetch + resolve for the similar sections: provider IDs, ranked and
/// de-duplicated in Core, resolved through the library. Any failure yields
/// an empty list — the section then simply does not show.
enum SimilarLoader {
    @MainActor
    static func tracks(similarTo trackID: String, excludingAlbumID: String?, limit: Int, container: DependencyContainer) async -> [Track] {
        guard let sonic = container.sonic, let library = container.library else { return [] }
        // Ask for a few more than shown: the seed's own album is filtered out.
        guard let results = try? await sonic.similarTracks(to: trackID, limit: limit + 10) else { return [] }
        let ids = rankedIDs(results, excluding: trackID, limit: limit + 10)
        guard let resolved = try? await library.tracks(byIDs: ids) else { return [] }
        let ordered = SimilarRanking.ordered(resolved, byIDs: ids)
        return Array(SimilarRanking.excludingAlbum(ordered, albumID: excludingAlbumID).prefix(limit))
    }

    @MainActor
    static func albums(similarTo albumID: String, limit: Int, container: DependencyContainer) async -> [Album] {
        guard let sonic = container.sonic, let lookup = container.libraryLookup else { return [] }
        guard let results = try? await sonic.similarAlbums(to: albumID, limit: limit) else { return [] }
        let ids = rankedIDs(results, excluding: albumID, limit: limit)
        return (try? await lookup.albums(byIDs: ids)) ?? []
    }

    @MainActor
    static func artists(similarTo artistID: String, limit: Int, container: DependencyContainer) async -> [Artist] {
        guard let sonic = container.sonic, let lookup = container.libraryLookup else { return [] }
        guard let results = try? await sonic.similarArtists(to: artistID, limit: limit) else { return [] }
        let ids = rankedIDs(results, excluding: artistID, limit: limit)
        return (try? await lookup.artists(byIDs: ids)) ?? []
    }

    private static func rankedIDs(_ results: [SimilarItem], excluding seedID: String, limit: Int) -> [String] {
        SimilarRanking.orderedIDs(
            from: results.map { (itemID: $0.itemID, distance: $0.distance) },
            excluding: seedID,
            limit: limit
        )
    }
}
