import AppIntents
import Foundation
import JellyampCore
import SwiftUI

// Siri / Shortcuts / Spotlight actions, built on the App Intents framework
// (no Intents extension, no SiriKit entitlement). Every intent runs in the
// app's own process — launched in the background if necessary — and goes
// through `MusicCommands`, which restores the session and produces the
// speakable errors ("You're not signed in", "Couldn't find …").

/// The audio-intent protocol tells the system these intents start or control
/// playback, so it lets the app begin playing from the background instead of
/// requiring it to come to the foreground.
///
/// Kept as one alias so a different protocol can be swapped in at a single
/// place should an SDK ever disagree about its availability.
typealias JellyampAudioIntent = AudioPlaybackIntent

// MARK: - Play

struct PlayMusicIntent: JellyampAudioIntent {
    static var title: LocalizedStringResource = "Play Music"
    static var description = IntentDescription(
        "Plays an artist, album, playlist, song or genre from your Jellyfin library.",
        categoryName: "Playback"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Music", requestValueDialog: IntentDialog("What would you like to hear?"))
    var target: MusicEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$target)") {
            \.$shuffle
        }
    }

    init() {}

    init(target: MusicEntity, shuffle: Bool = false) {
        self.target = target
        self.shuffle = shuffle
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let commands = try await MusicCommands.live()
        let summary = try await commands.play(target.ref, shuffled: shuffle)
        let spoken: String
        if let artist = summary.subtitle {
            spoken = String(localized: "Playing \(summary.title) by \(artist).")
        } else {
            spoken = String(localized: "Playing \(summary.title).")
        }
        return .result(
            dialog: IntentDialog(stringLiteral: spoken),
            view: IntentSnippetView(symbolName: target.symbolName, title: summary.title, subtitle: summary.subtitle)
        )
    }
}

struct ShuffleLikedSongsIntent: JellyampAudioIntent {
    static var title: LocalizedStringResource = "Shuffle Liked Songs"
    static var description = IntentDescription("Shuffles the songs you have liked.", categoryName: "Playback")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let commands = try await MusicCommands.live()
        try await commands.shuffleLikedSongs()
        return .result(dialog: IntentDialog(stringLiteral: String(localized: "Shuffling your liked songs.")))
    }
}

struct PlayRecentlyAddedIntent: JellyampAudioIntent {
    static var title: LocalizedStringResource = "Play Recently Added"
    static var description = IntentDescription("Plays the albums most recently added to your library.", categoryName: "Playback")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let commands = try await MusicCommands.live()
        let summary = try await commands.playRecentlyAdded()
        let spoken = String(localized: "Playing your newest music, starting with \(summary.title).")
        return .result(dialog: IntentDialog(stringLiteral: spoken))
    }
}

struct StartRadioIntent: JellyampAudioIntent {
    static var title: LocalizedStringResource = "Start Radio"
    static var description = IntentDescription(
        "Starts an endless station of similar music from an artist, genre, album or song.",
        categoryName: "Playback"
    )
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Based On", requestValueDialog: IntentDialog("Which artist or genre should the station be based on?"))
    var seed: MusicEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Start a station from \(\.$seed)")
    }

    init() {}

    init(seed: MusicEntity) {
        self.seed = seed
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let commands = try await MusicCommands.live()
        let summary = try await commands.startRadio(from: seed.ref)
        return .result(dialog: IntentDialog(stringLiteral: String(localized: "Starting \(summary.title) radio.")))
    }
}

// MARK: - Transport

struct ResumePlaybackIntent: JellyampAudioIntent {
    static var title: LocalizedStringResource = "Resume Playback"
    static var description = IntentDescription("Continues the current song.", categoryName: "Controls")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try await MusicCommands.live().resume()
        return .result()
    }
}

struct PausePlaybackIntent: JellyampAudioIntent {
    static var title: LocalizedStringResource = "Pause Playback"
    static var description = IntentDescription("Pauses the music.", categoryName: "Controls")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try await MusicCommands.live().pause()
        return .result()
    }
}

struct TogglePlaybackIntent: JellyampAudioIntent {
    static var title: LocalizedStringResource = "Play or Pause"
    static var description = IntentDescription("Pauses the music if it is playing, otherwise resumes it.", categoryName: "Controls")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await MusicCommands.live().togglePlayback()
        return .result()
    }
}

struct NextTrackIntent: JellyampAudioIntent {
    static var title: LocalizedStringResource = "Next Song"
    static var description = IntentDescription("Skips to the next song in the queue.", categoryName: "Controls")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try await MusicCommands.live().skipToNext()
        return .result()
    }
}

struct PreviousTrackIntent: JellyampAudioIntent {
    static var title: LocalizedStringResource = "Previous Song"
    static var description = IntentDescription("Goes back to the previous song.", categoryName: "Controls")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try await MusicCommands.live().skipToPrevious()
        return .result()
    }
}

// MARK: - Favorites

struct FavoriteCurrentSongIntent: AppIntent {
    static var title: LocalizedStringResource = "Like Current Song"
    static var description = IntentDescription("Adds the song that is playing to your liked songs.", categoryName: "Library")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let commands = try await MusicCommands.live()
        let track = try await commands.setCurrentTrackFavorite(true)
        let spoken = String(localized: "Added \(track.title) to your liked songs.")
        return .result(
            dialog: IntentDialog(stringLiteral: spoken),
            view: IntentSnippetView(symbolName: "heart.fill", title: track.title, subtitle: track.artistName)
        )
    }
}

// MARK: - Sleep timer

/// Sleep-timer lengths as an enum rather than a free duration: Siri can only
/// fill parameters inside an App Shortcut phrase from a fixed set of values,
/// and "Set a 30 minute sleep timer" must work hands-free.
enum SleepTimerLength: String, AppEnum {
    case minutes5
    case minutes10
    case minutes15
    case minutes30
    case minutes45
    case minutes60
    case minutes90
    case endOfTrack

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Sleep Timer Length"

    static var caseDisplayRepresentations: [SleepTimerLength: DisplayRepresentation] = [
        .minutes5: "5 minute",
        .minutes10: "10 minute",
        .minutes15: "15 minute",
        .minutes30: "30 minute",
        .minutes45: "45 minute",
        .minutes60: "60 minute",
        .minutes90: "90 minute",
        .endOfTrack: "end of song",
    ]

    /// Seconds, or nil for "when the current song ends".
    var duration: TimeInterval? {
        switch self {
        case .minutes5: return 5 * 60
        case .minutes10: return 10 * 60
        case .minutes15: return 15 * 60
        case .minutes30: return 30 * 60
        case .minutes45: return 45 * 60
        case .minutes60: return 60 * 60
        case .minutes90: return 90 * 60
        case .endOfTrack: return nil
        }
    }
}

struct SetSleepTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Sleep Timer"
    static var description = IntentDescription("Stops the music after a while, fading out at the end.", categoryName: "Controls")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Length", requestValueDialog: IntentDialog("How long should the music keep playing?"))
    var length: SleepTimerLength

    static var parameterSummary: some ParameterSummary {
        Summary("Set a \(\.$length) sleep timer")
    }

    init() {}

    init(length: SleepTimerLength) {
        self.length = length
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let commands = try await MusicCommands.live()
        try commands.startSleepTimer(duration: length.duration)
        let spoken: String
        if let duration = length.duration {
            let minutes = Int(duration / 60)
            spoken = String(localized: "The music will stop in \(minutes) minutes.")
        } else {
            spoken = String(localized: "The music will stop after this song.")
        }
        return .result(dialog: IntentDialog(stringLiteral: spoken))
    }
}

struct CancelSleepTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Cancel Sleep Timer"
    static var description = IntentDescription("Turns the sleep timer off.", categoryName: "Controls")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let commands = try await MusicCommands.live()
        commands.cancelSleepTimer()
        return .result(dialog: IntentDialog(stringLiteral: String(localized: "Sleep timer cancelled.")))
    }
}

// MARK: - Snippet

/// Compact confirmation card Siri and Shortcuts show next to the dialog.
/// Uses only static content: snippet views are archived and rendered by the
/// system, so they cannot load images or observe app state.
struct IntentSnippetView: View {
    let symbolName: String
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
    }
}
