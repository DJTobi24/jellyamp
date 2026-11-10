import SwiftUI
import AVKit
import MediaPlayer
import JellyampCore

/// Plexamp signature look: huge artwork over a blurred-art background, with
/// scrubber, transport controls and AirPlay. Tapping the artwork cycles the
/// visualizer (off → bars → wave), which is remembered in settings.
///
/// Layout adapts to the space it gets: a single column in portrait, artwork
/// left / controls right when the view is wider than tall (landscape, iPad).
struct NowPlayingView: View {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject var playerState: PlayerStateModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showQueue = false
    @State private var showLyrics = false
    @State private var visualizerTint: Color = .white

    var body: some View {
        GeometryReader { geometry in
            let isWide = geometry.size.width > geometry.size.height && geometry.size.width >= 560
            ZStack {
                BlurredArtBackground(track: playerState.currentTrack)
                if isWide {
                    wideLayout(size: geometry.size)
                } else {
                    compactLayout(size: geometry.size)
                }
            }
        }
        .sheet(isPresented: $showQueue) {
            QueueView(playerState: playerState)
                .environmentObject(container)
        }
        .sheet(isPresented: $showLyrics) {
            if let track = playerState.currentTrack {
                LyricsView(playerState: playerState, track: track)
                    .environmentObject(container)
            }
        }
        .task(id: playerState.currentTrack.map { "\($0.albumID ?? $0.id)|\($0.imageTag ?? "")" } ?? "") {
            await updateVisualizerTint()
        }
    }

    // MARK: - Layouts

    /// Portrait: one column. If it does not fit (small phone, large Dynamic
    /// Type) the same column scrolls instead of clipping.
    private func compactLayout(size: CGSize) -> some View {
        let side = (min(size.width - 56, size.height * 0.40, 460)).rounded(.down)
        let column = VStack(spacing: 14) {
            header
            artwork(side: max(side, 120))
                .padding(.vertical, 4)
            trackInfo
            errorBanner
            ScrubberView(playerState: playerState)
            PlayerControlsView(playerState: playerState)
            volumeRow
            bottomBar
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: horizontalSizeClass == .regular ? 560 : .infinity)
        .frame(maxWidth: .infinity)

        return ViewThatFits(in: .vertical) {
            column
            ScrollView(showsIndicators: false) { column }
        }
    }

    /// Landscape / iPad: artwork on the left, everything else on the right.
    private func wideLayout(size: CGSize) -> some View {
        let side = (min(size.height - 96, size.width * 0.42, 520)).rounded(.down)
        let controls = VStack(spacing: 12) {
            trackInfo
            errorBanner
            ScrubberView(playerState: playerState)
            PlayerControlsView(playerState: playerState)
            volumeRow
            bottomBar
        }
        .frame(maxWidth: 520)

        return VStack(spacing: 8) {
            header
            HStack(alignment: .center, spacing: 32) {
                artwork(side: max(side, 120))
                ViewThatFits(in: .vertical) {
                    controls
                    ScrollView(showsIndicators: false) { controls }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    // MARK: - Pieces

    private var visualizerStyle: VisualizerStyle { container.settings.visualizerStyle }

    /// Artwork, with the visualizer drawn over a dimmed cover when enabled.
    @ViewBuilder
    private func artwork(side: CGFloat) -> some View {
        if let track = playerState.currentTrack {
            Button {
                cycleVisualizer()
            } label: {
                ZStack {
                    ArtworkView(itemID: track.albumID ?? track.id, imageTag: track.imageTag, size: side)
                        .overlay {
                            if visualizerStyle != .off {
                                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.55))
                            }
                        }
                    if visualizerStyle != .off {
                        VisualizerView(style: visualizerStyle, tint: visualizerTint, isPlaying: playerState.isPlaying)
                            .padding(side * 0.08)
                            .frame(width: side, height: side)
                    }
                }
                .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Album artwork")
            .accessibilityValue(visualizerDescription)
            .accessibilityIdentifier(AccessibilityID.NowPlaying.artwork)
            .accessibilityHint("Changes the visualizer")
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .frame(width: side, height: side)
                .accessibilityHidden(true)
        }
    }

    private var visualizerDescription: String {
        switch visualizerStyle {
        case .off: return String(localized: "Visualizer off")
        case .bars: return String(localized: "Visualizer: bars")
        case .wave: return String(localized: "Visualizer: wave")
        }
    }

    private func cycleVisualizer() {
        let next: VisualizerStyle
        switch visualizerStyle {
        case .off: next = .bars
        case .bars: next = .wave
        case .wave: next = .off
        }
        Haptics.selection()
        if reduceMotion {
            container.settings.visualizerStyle = next
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { container.settings.visualizerStyle = next }
        }
        container.saveSettings()
    }

    private func updateVisualizerTint() async {
        guard let track = playerState.currentTrack, let session = container.session else {
            visualizerTint = .white
            return
        }
        if let color = await ArtworkPalette.shared.tint(for: track, session: session) {
            visualizerTint = Color(color)
        } else {
            visualizerTint = .white
        }
    }

    @ViewBuilder
    private var trackInfo: some View {
        if let track = playerState.currentTrack {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.title2.bold())
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Text(track.artistName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let quality = playerState.quality {
                        AudioQualityBadge(info: quality)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AccessibilityID.NowPlaying.trackInfo)

                // The shared heart: reads and writes through
                // `FavoritesModel`, like every other heart in the app.
                FavoriteButton(itemID: track.id, isFavorite: track.isFavorite, inNowPlaying: true)

                trackMenu(track)
            }
            .padding(.horizontal)
        }
    }

    /// "Go to Album / Artist" navigate in the app underneath: `AppNavigator`
    /// pushes the page onto the Library stack and the cover closes itself to
    /// reveal it (`libraryCoverPresentation`, applied where the cover is
    /// presented). "Add to Playlist" opens the shared sheet above the cover.
    private func trackMenu(_ track: Track) -> some View {
        Menu {
            if let route = LibraryRoute.albumRoute(for: track) {
                Button {
                    AppNavigator.shared.open(route)
                } label: { Label("Go to Album", systemImage: "square.stack") }
            }
            if let route = LibraryRoute.artistRoute(for: track) {
                Button {
                    AppNavigator.shared.open(route)
                } label: { Label("Go to Artist", systemImage: "music.mic") }
            }
            Button {
                AppNavigator.shared.playlistRequest = PlaylistAddRequest(track: track)
            } label: { Label("Add to Playlist…", systemImage: "text.badge.plus") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More")
        .accessibilityIdentifier(AccessibilityID.NowPlaying.more)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let errorMessage = playerState.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    private var volumeRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            // System/output volume — also controls the AirPlay device.
            SystemVolumeSlider()
                .frame(height: 28)
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Volume")
    }

    private var bottomBar: some View {
        HStack(spacing: 28) {
            AirPlayRoutePicker()
                .frame(width: 44, height: 44)
                .accessibilityLabel("AirPlay")
            Button {
                showLyrics = true
            } label: {
                Image(systemName: "quote.bubble")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(playerState.currentTrack == nil)
            .accessibilityLabel("Lyrics")
            .accessibilityIdentifier(AccessibilityID.NowPlaying.lyrics)
            Button {
                cycleVisualizer()
            } label: {
                Image(systemName: visualizerStyle == .wave ? "waveform.path" : "waveform")
                    .font(.title3)
                    .foregroundStyle(visualizerStyle == .off ? Color.secondary : visualizerTint)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Visualizer")
            .accessibilityValue(visualizerDescription)
            .accessibilityIdentifier(AccessibilityID.NowPlaying.visualizer)
            Button {
                showQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Queue")
            .accessibilityValue("\(playerState.upNext.count) up next")
            .accessibilityIdentifier(AccessibilityID.NowPlaying.queue)
        }
    }

    private var header: some View {
        HStack {
            headerButton(systemName: "chevron.down", label: "Close Player") { dismiss() }
                .accessibilityIdentifier(AccessibilityID.NowPlaying.close)
            Spacer()
            if let album = playerState.currentTrack?.albumName {
                Text(album)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("Album: \(album)")
            }
            Spacer()
            sleepTimerMenu
        }
    }

    private var sleepTimerMenu: some View {
        Menu {
            ForEach([15, 30, 45, 60], id: \.self) { minutes in
                Button("\(minutes) minutes") {
                    container.player?.startSleepTimer(duration: TimeInterval(minutes * 60))
                }
            }
            Button("End of track") {
                container.player?.startSleepTimer(duration: nil)
            }
            if playerState.sleepTimerActive {
                Button("Turn off", role: .destructive) {
                    container.player?.cancelSleepTimer()
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: playerState.sleepTimerActive ? "moon.fill" : "moon")
                    .font(.title3.bold())
                if let remaining = playerState.sleepTimerRemaining {
                    Text(PlaybackTimeFormat.clock(remaining))
                        .font(.caption.monospacedDigit())
                }
            }
            .foregroundStyle(playerState.sleepTimerActive ? AnyShapeStyle(.purple) : AnyShapeStyle(.secondary))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sleep Timer")
        .accessibilityValue(sleepTimerDescription)
    }

    private var sleepTimerDescription: String {
        guard playerState.sleepTimerActive else { return String(localized: "Off") }
        if let remaining = playerState.sleepTimerRemaining {
            return String(localized: "\(PlaybackTimeFormat.spoken(remaining)) remaining")
        }
        return String(localized: "Stops at the end of this track")
    }

    private func headerButton(systemName: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3.bold())
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Codec · resolution · bitrate, plus how the audio reaches the device.
struct AudioQualityBadge: View {
    let info: AudioQualityInfo

    var body: some View {
        HStack(spacing: 6) {
            if info.isLossless {
                Text(info.isHiRes ? "HI-RES" : "LOSSLESS")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
            }
            Text(info.summary)
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Image(systemName: deliveryIcon)
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio quality")
        .accessibilityValue(accessibilityText)
    }

    private var deliveryIcon: String {
        switch info.delivery {
        case .direct: return "dot.radiowaves.left.and.right"
        case .transcoded: return "arrow.triangle.2.circlepath"
        case .downloaded: return "arrow.down.circle.fill"
        }
    }

    private var deliveryText: String {
        switch info.delivery {
        case .direct: return String(localized: "streamed directly")
        case .transcoded: return String(localized: "transcoded by the server")
        case .downloaded: return String(localized: "downloaded")
        }
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if info.isLossless {
            parts.append(info.isHiRes ? String(localized: "High resolution lossless") : String(localized: "Lossless"))
        }
        parts.append(info.summary)
        parts.append(deliveryText)
        return parts.joined(separator: ", ")
    }
}

/// Blurred cover behind the player. With Reduce Transparency on, the blur is
/// replaced by a plain dark background so text keeps its contrast.
struct BlurredArtBackground: View {
    @EnvironmentObject private var container: DependencyContainer
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let track: Track?

    var body: some View {
        Group {
            if let track, !reduceTransparency {
                ArtworkView(itemID: track.albumID ?? track.id, imageTag: track.imageTag, size: 400)
                    .blur(radius: 60)
                    .opacity(0.6)
                    .scaleEffect(1.5)
            } else {
                Color.black
            }
        }
        // Fill the container: otherwise the black backdrop only covers the
        // artwork's own 400 pt square, which showed as a hard-edged box
        // wherever the parent is not black itself (the lyrics sheet).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// System output-volume slider (`MPVolumeView`). Unlike a player-node volume,
/// this controls the actual route volume, so it also works over AirPlay.
/// Note: it's inert in the Simulator (no audio hardware).
struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.tintColor = .white
        if let slider = view.subviews.compactMap({ $0 as? UISlider }).first {
            slider.minimumTrackTintColor = .white
        }
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

/// System AirPlay route picker (speakers, AirPods, Apple TV, …).
struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemPurple
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
