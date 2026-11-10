import SwiftUI
import Combine
import JellyampCore
import JellyfinBackend

// MARK: - Track row

/// The one track row used by every list: tap to play, "⋯" menu, long-press
/// menu, and a single VoiceOver element ("Title, Artist, 3 minutes") that
/// carries the menu as custom actions.
struct TrackRow: View {
    enum Leading: Equatable {
        case artwork
        /// Track number (album screens).
        case number(Int)
    }

    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject private var favorites = FavoritesModel.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isCurrent = false

    /// What the second line shows.
    enum Subtitle: Equatable {
        case artist, album, artistAndAlbum
        case none
    }

    private let track: Track
    private let leading: Leading
    private let subtitleStyle: Subtitle
    private let showsDuration: Bool
    private let play: () -> Void

    init(
        track: Track,
        leading: Leading = .artwork,
        subtitle: Subtitle = .artist,
        showsDuration: Bool = true,
        play: @escaping () -> Void
    ) {
        self.track = track
        self.leading = leading
        self.subtitleStyle = subtitle
        self.showsDuration = showsDuration
        self.play = play
    }

    private var subtitle: String? {
        let text: String
        switch subtitleStyle {
        case .artist: text = track.artistName
        case .album: text = track.albumName ?? ""
        case .artistAndAlbum:
            text = [track.artistName, track.albumName ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        case .none: text = ""
        }
        return text.isEmpty ? nil : text
    }

    private var isFavorite: Bool { favorites.isFavorite(track.id, serverValue: track.isFavorite) }
    private var isDownloaded: Bool { container.downloads?.isDownloaded(track.id) ?? false }
    private var largeText: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: play) {
                HStack(spacing: 12) {
                    leadingView
                    VStack(alignment: .leading, spacing: 2) {
                        // The app tint is white, so the playing row is
                        // marked by weight and an icon rather than by color.
                        HStack(spacing: 6) {
                            if isCurrent, leading == .artwork {
                                Image(systemName: "waveform")
                                    .font(.caption)
                                    .foregroundStyle(.pink)
                            }
                            Text(track.title)
                                .fontWeight(isCurrent ? .semibold : .regular)
                                .lineLimit(largeText ? 3 : 1)
                        }
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(largeText ? 2 : 1)
                        }
                    }
                    Spacer(minLength: 4)
                    if isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(.pink)
                    }
                    if isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // The duration is part of the VoiceOver label; at large
                    // text sizes the title needs the room more.
                    if showsDuration, !largeText, track.duration >= 1 {
                        Text(DurationText.clock(track.duration))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            TrackMenuButton(track: track)
        }
        .trackContextActions(track)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text("Plays the song"))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, play)
        .trackAccessibilityActions(track)
        .accessibilityIdentifier(AccessibilityID.Item.track(track.id))
        .onReceive(container.playerState.$currentTrack.map { $0?.id }.removeDuplicates()) { id in
            isCurrent = id == track.id
        }
    }

    @ViewBuilder
    private var leadingView: some View {
        switch leading {
        case .artwork:
            ArtworkView(itemID: track.albumID ?? track.id, imageTag: track.imageTag, size: 44)
        case .number(let number):
            Group {
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill").font(.caption)
                } else {
                    Text("\(number)").monospacedDigit()
                }
            }
            .foregroundStyle(isCurrent ? Color.pink : Color.secondary)
            .frame(minWidth: 28, alignment: .trailing)
        }
    }

    private var accessibilityLabel: String {
        var number: Int?
        if case .number(let value) = leading { number = value }
        var label = AccessibilityText.trackRow(track, trackNumber: number, detail: subtitle ?? "")
        if isCurrent { label += ", " + String(localized: "now playing") }
        if isFavorite { label += ", " + String(localized: "liked") }
        if isDownloaded { label += ", " + String(localized: "downloaded") }
        return label
    }
}

// MARK: - Artwork

/// Square artwork that takes the width it is given (grid cells), unlike
/// `ArtworkView`, which needs a fixed size.
struct ArtworkTile: View {
    @EnvironmentObject private var container: DependencyContainer
    let itemID: String
    let imageTag: String?
    var isCircle = false
    var systemImage = "music.note"

    var body: some View {
        Color.white.opacity(0.08)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AsyncImage(url: imageURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: systemImage)
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: isCircle ? 1000 : 8))
            .accessibilityHidden(true)
    }

    private var imageURL: URL? {
        guard let session = container.session else { return nil }
        // One size for all grid cells: at most ~200 pt wide at 3x.
        return ImageURLBuilder.url(itemID: itemID, tag: imageTag, maxWidth: 600, session: session)
    }
}

// MARK: - Album, artist, playlist cells

/// Album tile for grids: flexible artwork, two-line title, artist or year.
struct AlbumGridCell: View {
    let album: Album
    /// Show the year instead of the artist (artist pages).
    var showsYear = false

    private var secondLine: String {
        if showsYear { return album.productionYear.map { String($0) } ?? "" }
        return album.artistName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ArtworkTile(itemID: album.id, imageTag: album.imageTag, systemImage: "square.stack")
            Text(album.title)
                .font(.callout)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if !secondLine.isEmpty {
                Text(secondLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(AccessibilityText.album(album)))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(AccessibilityID.Item.album(album.id))
    }
}

/// Album as a list row (search results, grids at accessibility text sizes).
struct AlbumListRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let album: Album

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(itemID: album.id, imageTag: album.imageTag, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(AccessibilityText.album(album)))
        .accessibilityIdentifier(AccessibilityID.Item.album(album.id))
    }

    private var detail: String {
        var parts: [String] = []
        if !album.artistName.isEmpty { parts.append(album.artistName) }
        if let year = album.productionYear, year > 0 { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }
}

struct ArtistListRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let artist: Artist

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(itemID: artist.id, imageTag: artist.imageTag, size: 48)
                .clipShape(Circle())
            Text(artist.name)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(artist.name))
        .accessibilityIdentifier(AccessibilityID.Item.artist(artist.id))
    }
}

struct PlaylistListRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let playlist: Playlist

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(itemID: playlist.id, imageTag: playlist.imageTag, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                if let count = playlist.trackCount {
                    Text(count == 1 ? "1 song" : "\(count) songs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(AccessibilityText.playlist(playlist)))
        .accessibilityIdentifier(AccessibilityID.Item.playlist(playlist.id))
    }
}

// MARK: - Play / Shuffle

/// The Play + Shuffle pair under every collection header. `accessory` is the
/// place for extra header buttons (favorite heart, "⋯", download).
struct PlayShuffleBar<Accessory: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let isEnabled: Bool
    let play: () -> Void
    let shuffle: () -> Void
    let accessory: Accessory

    init(
        isEnabled: Bool,
        play: @escaping () -> Void,
        shuffle: @escaping () -> Void,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.isEnabled = isEnabled
        self.play = play
        self.shuffle = shuffle
        self.accessory = accessory()
    }

    var body: some View {
        // At accessibility sizes the two labels no longer fit side by side
        // with the accessories, so the accessories move to their own line.
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                buttons
                HStack(spacing: 4) { accessory }
            }
        } else {
            HStack(spacing: 8) {
                buttons
                accessory
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button(action: play) {
            Label("Play", systemImage: "play.fill")
                // Black on the white tint: 21:1 contrast.
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!isEnabled)
        .accessibilityIdentifier(AccessibilityID.Collection.play)
        Button(action: shuffle) {
            Label("Shuffle", systemImage: "shuffle")
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.bordered)
        .disabled(!isEnabled)
        .accessibilityIdentifier(AccessibilityID.Collection.shuffle)
    }
}

extension PlayShuffleBar where Accessory == EmptyView {
    init(isEnabled: Bool, play: @escaping () -> Void, shuffle: @escaping () -> Void) {
        self.init(isEnabled: isEnabled, play: play, shuffle: shuffle) { EmptyView() }
    }
}
