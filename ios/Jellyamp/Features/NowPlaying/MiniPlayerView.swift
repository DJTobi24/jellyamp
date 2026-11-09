import SwiftUI
import JellyampCore

/// Persistent bottom bar above the tab bar; tap to expand into NowPlayingView,
/// swipe left / right to skip to the next / previous track. A hairline along
/// the bottom edge shows progress.
struct MiniPlayerView: View {
    @EnvironmentObject private var container: DependencyContainer
    @EnvironmentObject private var playerState: PlayerStateModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showNowPlaying = false
    @State private var dragOffset: CGFloat = 0

    /// Horizontal travel that counts as a skip.
    private let swipeThreshold: CGFloat = 56

    var body: some View {
        if let track = playerState.currentTrack {
            // Two sibling buttons (not nested): the info area opens the full
            // player, the play/pause button toggles playback. Nesting them
            // would let the outer button swallow the pause tap.
            HStack(spacing: 12) {
                Button {
                    showNowPlaying = true
                } label: {
                    HStack(spacing: 12) {
                        ArtworkView(itemID: track.albumID ?? track.id, imageTag: track.imageTag, size: 44)
                        VStack(alignment: .leading) {
                            Text(track.title)
                                .font(.callout)
                                .lineLimit(1)
                            if let errorMessage = playerState.errorMessage {
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                            } else {
                                Text(track.artistName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .offset(x: dragOffset)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(infoLabel(for: track))
                .accessibilityHint("Opens the player")
                .accessibilityAction(named: Text("Next Track")) { container.player?.skipToNext() }
                .accessibilityAction(named: Text("Previous Track")) { container.player?.skipToPrevious() }

                Button {
                    Haptics.transport()
                    if playerState.isPlaying || playerState.isLoading {
                        container.player?.pause()
                    } else {
                        container.player?.play()
                    }
                } label: {
                    ZStack {
                        Image(systemName: playerState.isPlaying || playerState.isLoading ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .opacity(playerState.isLoading ? 0.3 : 1)
                        if playerState.isLoading {
                            ProgressView()
                        }
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playerState.isPlaying || playerState.isLoading ? "Pause" : "Play")
            }
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                progressHairline(duration: track.duration)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .glassPanel(cornerRadius: 16)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            // Simultaneous: taps still reach the buttons, a sideways drag skips.
            .simultaneousGesture(swipeGesture)
            .fullScreenCover(isPresented: $showNowPlaying) {
                NowPlayingView(playerState: playerState)
                    .environmentObject(container)
            }
        }
    }

    private func infoLabel(for track: Track) -> String {
        if let errorMessage = playerState.errorMessage {
            return String(localized: "\(track.title), \(errorMessage)")
        }
        return String(localized: "Now playing: \(track.title), \(track.artistName)")
    }

    private func progressHairline(duration: TimeInterval) -> some View {
        GeometryReader { geometry in
            let fraction = duration > 0 ? min(max(playerState.currentTime / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.12))
                Rectangle().fill(Color.white.opacity(0.85))
                    .frame(width: geometry.size.width * CGFloat(fraction))
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                // Follow the finger only for clearly horizontal drags.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = reduceMotion ? 0 : value.translation.width * 0.35
            }
            .onEnded { value in
                let horizontal = value.translation.width
                let isHorizontal = abs(horizontal) > abs(value.translation.height) * 1.5
                if isHorizontal, horizontal <= -swipeThreshold {
                    Haptics.transport()
                    container.player?.skipToNext()
                } else if isHorizontal, horizontal >= swipeThreshold {
                    Haptics.transport()
                    container.player?.skipToPrevious()
                }
                if reduceMotion {
                    dragOffset = 0
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { dragOffset = 0 }
                }
            }
    }
}
