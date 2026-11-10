import SwiftUI
import JellyampCore

/// Sizes that differ between phone and iPad widths.
struct HomeMetrics {
    let cardSize: CGFloat
    let trackCardSize: CGFloat
    /// Leading/trailing inset of shelf titles and the first/last card.
    let inset: CGFloat

    init(isWide: Bool) {
        cardSize = isWide ? 184 : 150
        trackCardSize = isWide ? 150 : 120
        inset = isWide ? 28 : 16
    }
}

/// A titled, horizontally scrolling row of cards. The row scrolls edge to
/// edge; only the title and the first/last card are inset.
struct HomeShelf<Content: View>: View {
    private let title: LocalizedStringKey
    private let inset: CGFloat
    private let content: Content

    init(_ title: LocalizedStringKey, inset: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.title = title
        self.inset = inset
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())
                .padding(.horizontal, inset)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    content
                }
                .padding(.horizontal, inset)
            }
        }
    }
}

/// The "Stations" and "Time Travel" shelves. Tapping a card starts the
/// station through `StationCoordinator`, which keeps the queue topped up.
struct HomeStationShelves: View {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject var stations: StationCoordinator
    let shelves: StationCatalog.Shelves
    let metrics: HomeMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !shelves.stations.isEmpty {
                HomeShelf("Stations", inset: metrics.inset) {
                    cards(for: shelves.stations)
                }
            }
            if !shelves.timeTravel.isEmpty {
                HomeShelf("Time Travel", inset: metrics.inset) {
                    cards(for: shelves.timeTravel)
                }
            }
        }
        .alert("Station Unavailable", isPresented: failureBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(stations.failureMessage ?? "")
        }
    }

    private func cards(for definitions: [StationDefinition]) -> some View {
        ForEach(definitions) { station in
            Button {
                stations.start(station, container: container)
            } label: {
                StationCard(
                    station: station,
                    size: metrics.cardSize,
                    isActive: stations.activeStation?.id == station.id,
                    isLoading: stations.startingStationID == station.id
                )
            }
            .buttonStyle(.plain)
            .disabled(stations.startingStationID != nil)
        }
    }

    private var failureBinding: Binding<Bool> {
        Binding(
            get: { stations.failureMessage != nil },
            set: { isPresented in
                if !isPresented { stations.failureMessage = nil }
            }
        )
    }
}

/// Square tile for a station: artist artwork for artist radio, a tinted
/// gradient with a symbol (or the decade) for generated stations.
struct StationCard: View {
    let station: StationDefinition
    var size: CGFloat = 150
    var isActive: Bool = false
    var isLoading: Bool = false

    var body: some View {
        VStack(alignment: .leading) {
            artwork
                .frame(width: size, height: size)
                .overlay { statusOverlay }
            Text(station.title)
                .font(.callout)
                .lineLimit(1)
            Text(kindLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: size)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    @ViewBuilder
    private var artwork: some View {
        if let itemID = station.artworkItemID {
            ArtworkView(itemID: itemID, imageTag: station.artworkImageTag, size: size)
                .clipShape(Circle())
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(Color.black.opacity(0.6), in: Circle())
                }
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [tint, tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay { emblem }
        }
    }

    @ViewBuilder
    private var emblem: some View {
        switch station.seed {
        case .decade(let decade):
            Text(decade.shortTitle)
                .font(.system(size: size * 0.3, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        case .library:
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: size * 0.3))
                .foregroundStyle(.white)
        case .genre, .artist, .track:
            Image(systemName: "music.quarternote.3")
                .font(.system(size: size * 0.3))
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if isLoading {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.45))
                ProgressView().tint(.white)
            }
        } else if isActive {
            Image(systemName: "waveform")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .padding(8)
                .background(Color.black.opacity(0.6), in: Circle())
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    private var kindLabel: LocalizedStringKey {
        switch station.seed {
        case .library: return "Your whole library"
        case .genre: return "Genre Station"
        case .decade: return "Decade Station"
        case .artist: return "Artist Radio"
        case .track: return "Track Radio"
        }
    }

    /// Hue derived from the station ID so each station keeps its color
    /// across launches (`hashValue` is seeded per process).
    private var tint: Color {
        var sum = 0
        for scalar in station.id.unicodeScalars {
            sum = (sum &* 31 &+ Int(scalar.value)) % 360
        }
        return Color(hue: Double(sum) / 360, saturation: 0.6, brightness: 0.7)
    }
}

/// First-load placeholder: grey shelves in the shape of the real ones, so
/// the layout does not jump when content arrives.
struct HomeSkeleton: View {
    let metrics: HomeMetrics
    @State private var isDimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                        .frame(width: 160, height: 22)
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(0..<6, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 8) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.quaternary)
                                    .frame(width: metrics.cardSize, height: metrics.cardSize)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(.quaternary)
                                    .frame(width: metrics.cardSize * 0.7, height: 12)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, metrics.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .opacity(isDimmed ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: isDimmed)
        .onAppear { isDimmed = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}
