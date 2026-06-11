import SwiftUI
import AVKit
import JellyampCore

/// Plexamp signature look: huge artwork over a blurred-art background, with
/// scrubber, transport controls and AirPlay. Queue sheet, lyrics, and
/// visualizer attach here in later phases.
struct NowPlayingView: View {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject var playerState: PlayerStateModel
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false
    @State private var isFavorite = false

    var body: some View {
        ZStack {
            BlurredArtBackground(track: playerState.currentTrack)
            VStack(spacing: 22) {
                header
                Spacer(minLength: 8)
                if let track = playerState.currentTrack {
                    ArtworkView(itemID: track.albumID ?? track.id, imageTag: track.imageTag, size: 300)
                        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                    trackInfo(track)
                        .task(id: track.id) { isFavorite = track.isFavorite }
                }
                if let errorMessage = playerState.errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                ProgressSection(playerState: playerState)
                PlayerControlsView(playerState: playerState)
                AirPlayRoutePicker()
                    .frame(width: 44, height: 44)
                Spacer(minLength: 8)
            }
            .padding()
        }
        .sheet(isPresented: $showQueue) {
            QueueView(playerState: playerState)
                .environmentObject(container)
        }
    }

    private func trackInfo(_ track: Track) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.title2.bold())
                    .lineLimit(1)
                Text(track.artistName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                isFavorite.toggle()
                let target = isFavorite
                Task { try? await container.library?.setFavorite(itemID: track.id, isFavorite: target) }
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.title2)
                    .foregroundStyle(isFavorite ? .pink : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
    }

    private var header: some View {
        HStack {
            headerButton(systemName: "chevron.down") { dismiss() }
            Spacer()
            if let album = playerState.currentTrack?.albumName {
                Text(album)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            headerButton(systemName: "list.bullet") { showQueue = true }
        }
    }

    private func headerButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3.bold())
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Spotify-style "Up Next" queue: tap a row to jump to it, swipe to remove.
struct QueueView: View {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject var playerState: PlayerStateModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let current = playerState.currentTrack {
                    Section("Now Playing") {
                        QueueRow(track: current)
                    }
                }
                Section("Up Next") {
                    if playerState.upNext.isEmpty {
                        Text("Queue is empty.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(playerState.upNext.enumerated()), id: \.offset) { index, track in
                            Button {
                                container.player?.playUpNext(at: index)
                            } label: {
                                QueueRow(track: track)
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            for index in offsets.sorted(by: >) {
                                container.player?.removeUpNext(at: index)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Queue")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct QueueRow: View {
    let track: Track

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(itemID: track.albumID ?? track.id, imageTag: track.imageTag, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                Text(track.artistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Scrubber with elapsed / remaining labels. Scrubbing updates a local value
/// and only seeks on release so the periodic time observer doesn't fight the
/// user's finger.
private struct ProgressSection: View {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject var playerState: PlayerStateModel
    @State private var scrubTime: Double?

    var body: some View {
        let duration = max(playerState.currentTrack?.duration ?? 1, 1)
        let position = scrubTime ?? min(playerState.currentTime, duration)
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { position },
                    set: { scrubTime = $0 }
                ),
                in: 0...duration
            ) { editing in
                if !editing, let target = scrubTime {
                    container.player?.seek(to: target)
                    // Clear on the next runloop: the slider fires this inside a
                    // view-update transaction, and mutating @State synchronously
                    // here trips "modifying state during view update".
                    DispatchQueue.main.async { scrubTime = nil }
                }
            }
            .tint(.white)
            HStack {
                Text(format(position))
                Spacer()
                Text("-" + format(max(duration - position, 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct BlurredArtBackground: View {
    @EnvironmentObject private var container: DependencyContainer
    let track: Track?

    var body: some View {
        Group {
            if let track {
                ArtworkView(itemID: track.albumID ?? track.id, imageTag: track.imageTag, size: 400)
                    .blur(radius: 60)
                    .opacity(0.6)
                    .scaleEffect(1.5)
            } else {
                Color.black
            }
        }
        .ignoresSafeArea()
        .background(Color.black)
    }
}

struct PlayerControlsView: View {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject var playerState: PlayerStateModel

    var body: some View {
        HStack(spacing: 40) {
            Button {
                container.player?.skipToPrevious()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title3)
            }
            Button {
                playerState.isPlaying ? container.player?.pause() : container.player?.play()
            } label: {
                Image(systemName: playerState.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 54))
            }
            Button {
                container.player?.skipToNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .glassCapsule()
    }
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

/// Observable bridge between `PlayerEngine` state and SwiftUI. A single
/// instance lives in `DependencyContainer` and is fed by `EnginePlayer`
/// (always on the main thread) and injected into the player views.
final class PlayerStateModel: ObservableObject {
    @Published var currentTrack: Track?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    /// Upcoming tracks after the current one, for the Up Next / queue view.
    @Published var upNext: [Track] = []
    /// Non-nil when the current track failed to start; surfaced in the UI.
    @Published var errorMessage: String?
}
