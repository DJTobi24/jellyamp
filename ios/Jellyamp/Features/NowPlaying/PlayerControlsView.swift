import SwiftUI
import UIKit
import JellyampCore

/// Light haptic feedback for transport controls. Generators are cheap to
/// create; the system ignores them on devices without a Taptic Engine.
enum Haptics {
    /// Play/pause, next, previous.
    static func transport() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Toggles (shuffle, repeat, favorite) and scrub commits.
    static func toggle() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

/// Time strings for the player: "3:07" on screen, "3 minutes, 7 seconds" for
/// VoiceOver.
enum PlaybackTimeFormat {
    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds.rounded(.down)))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static let spokenFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter
    }()

    static func spoken(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "" }
        return spokenFormatter.string(from: max(0, seconds.rounded(.down))) ?? clock(seconds)
    }
}

/// Shuffle · previous · play/pause · next · repeat.
struct PlayerControlsView: View {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject var playerState: PlayerStateModel
    @ScaledMetric(relativeTo: .largeTitle) private var playSize: CGFloat = 54

    var body: some View {
        HStack(spacing: 14) {
            Button {
                Haptics.toggle()
                container.player?.setShuffle(!playerState.isShuffled)
            } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundStyle(playerState.isShuffled ? Color.purple : Color.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Shuffle")
            .accessibilityValue(playerState.isShuffled ? "On" : "Off")
            .accessibilityIdentifier(AccessibilityID.NowPlaying.shuffle)

            Button {
                Haptics.transport()
                container.player?.skipToPrevious()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Previous Track")
            .accessibilityIdentifier(AccessibilityID.NowPlaying.previous)

            Button {
                Haptics.transport()
                if playerState.isPlaying || playerState.isLoading {
                    container.player?.pause()
                } else {
                    container.player?.play()
                }
            } label: {
                ZStack {
                    Image(systemName: playerState.isPlaying || playerState.isLoading ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: min(playSize, 80)))
                        .opacity(playerState.isLoading ? 0.35 : 1)
                    if playerState.isLoading {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .frame(minWidth: 56, minHeight: 56)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(playerState.isPlaying || playerState.isLoading ? "Pause" : "Play")
            .accessibilityValue(playerState.isLoading ? "Loading" : "")
            .accessibilityIdentifier(AccessibilityID.NowPlaying.playPause(isPlaying: playerState.isPlaying || playerState.isLoading))

            Button {
                Haptics.transport()
                container.player?.skipToNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Next Track")
            .accessibilityIdentifier(AccessibilityID.NowPlaying.next)

            Button {
                Haptics.toggle()
                container.player?.cycleRepeatMode()
            } label: {
                Image(systemName: playerState.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.title3)
                    .foregroundStyle(playerState.repeatMode == .off ? Color.white : Color.purple)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Repeat")
            .accessibilityValue(repeatDescription)
            .accessibilityIdentifier(AccessibilityID.NowPlaying.repeatMode)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassCapsule()
    }

    private var repeatDescription: String {
        switch playerState.repeatMode {
        case .off: return String(localized: "Off")
        case .all: return String(localized: "All")
        case .one: return String(localized: "One")
        }
    }
}

/// Scrubber with elapsed / remaining labels.
///
/// The whole 44-pt-high strip is the touch target and dragging is relative
/// (like the system player): put a finger anywhere and move — no need to hit
/// the thumb, and a stray tap never jumps the track. The position follows
/// the finger locally and the engine seeks once, on release.
struct ScrubberView: View {
    @EnvironmentObject private var container: DependencyContainer
    @ObservedObject var playerState: PlayerStateModel
    /// Right-hand label: time remaining ("-1:23") or total duration.
    @AppStorage("nowPlaying.showsTimeRemaining") private var showsRemaining = true
    @State private var scrubTime: Double?
    @State private var scrubOrigin: Double?

    private var duration: Double { max(playerState.currentTrack?.duration ?? 0, 0) }
    private var position: Double {
        if let scrubTime { return scrubTime }
        return duration > 0 ? min(max(playerState.currentTime, 0), duration) : max(playerState.currentTime, 0)
    }
    private var fraction: Double { duration > 0 ? position / duration : 0 }
    private var isScrubbing: Bool { scrubTime != nil }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let width = max(geometry.size.width, 1)
                let barHeight: CGFloat = isScrubbing ? 8 : 4
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.25))
                        .frame(height: barHeight)
                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(0, min(width, width * CGFloat(fraction))), height: barHeight)
                    Circle()
                        .fill(Color.white)
                        .frame(width: isScrubbing ? 18 : 10, height: isScrubbing ? 18 : 10)
                        .offset(x: max(0, min(width, width * CGFloat(fraction))) - (isScrubbing ? 9 : 5))
                }
                .frame(width: width, height: geometry.size.height)
                .contentShape(Rectangle())
                .gesture(dragGesture(width: width))
            }
            .frame(height: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback position")
            .accessibilityValue(accessibilityPosition)
            .accessibilityIdentifier(AccessibilityID.NowPlaying.scrubber)
            .accessibilityAdjustableAction { direction in
                adjust(direction)
            }

            HStack {
                Text(PlaybackTimeFormat.clock(position))
                    .accessibilityHidden(true)
                Spacer()
                Button {
                    showsRemaining.toggle()
                    Haptics.selection()
                } label: {
                    Text(showsRemaining
                         ? "-" + PlaybackTimeFormat.clock(max(duration - position, 0))
                         : PlaybackTimeFormat.clock(duration))
                        .frame(minWidth: 44, minHeight: 28, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsRemaining ? "Time remaining" : "Track length")
                .accessibilityValue(PlaybackTimeFormat.spoken(showsRemaining ? max(duration - position, 0) : duration))
                .accessibilityHint("Switches between time remaining and track length")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .opacity(duration > 0 ? 1 : 0.4)
        .allowsHitTesting(duration > 0)
    }

    private var accessibilityPosition: String {
        guard duration > 0 else { return String(localized: "Unknown") }
        return String(localized: "\(PlaybackTimeFormat.spoken(position)) of \(PlaybackTimeFormat.spoken(duration))")
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard duration > 0 else { return }
                let origin = scrubOrigin ?? position
                if scrubOrigin == nil {
                    scrubOrigin = origin
                    Haptics.selection()
                }
                let delta = Double(value.translation.width / width) * duration
                scrubTime = min(max(origin + delta, 0), duration)
            }
            .onEnded { _ in
                if let target = scrubTime {
                    container.player?.seek(to: target)
                    Haptics.toggle()
                }
                scrubOrigin = nil
                // The engine publishes the target position synchronously in
                // seek(to:), so dropping the local value does not flash back.
                scrubTime = nil
            }
    }

    /// VoiceOver swipe up/down: move by 10 seconds (5 % on long tracks).
    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        guard duration > 0 else { return }
        let step = max(10, duration * 0.05)
        switch direction {
        case .increment:
            container.player?.seek(to: min(position + step, duration))
        case .decrement:
            container.player?.seek(to: max(position - step, 0))
        @unknown default:
            break
        }
    }
}
