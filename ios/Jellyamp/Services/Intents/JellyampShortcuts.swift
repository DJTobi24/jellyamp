import AppIntents

/// The App Shortcuts: intents that work in Siri, Spotlight and the Shortcuts
/// app the moment Jellyamp is installed, with no setup by the user.
///
/// Rules the phrases follow (the build's App Intents metadata step enforces
/// the first two): every phrase names the app via `\(.applicationName)`, a
/// phrase holds at most one parameter, and the provider stays within the
/// system limit of 10 shortcuts. Phrases are literals on purpose — they are
/// extracted at build time, not evaluated at run time.
///
/// Requires iOS 16.4 for the short titles and symbols shown on the Shortcuts
/// and Spotlight tiles; on 16.0–16.3 the intents are still available as
/// actions in the Shortcuts editor, just without ready-made phrases.
@available(iOS 16.4, *)
struct JellyampShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayMusicIntent(),
            phrases: [
                "Play \(\.$target) in \(.applicationName)",
                "Play \(\.$target) on \(.applicationName)",
                "Listen to \(\.$target) in \(.applicationName)",
                "Play music in \(.applicationName)",
                "Play something in \(.applicationName)",
            ],
            shortTitle: "Play Music",
            systemImageName: "play.circle.fill"
        )
        AppShortcut(
            intent: ShuffleLikedSongsIntent(),
            phrases: [
                "Shuffle my liked songs in \(.applicationName)",
                "Shuffle my favorites in \(.applicationName)",
                "Play my liked songs in \(.applicationName)",
                "Play my favorites in \(.applicationName)",
            ],
            shortTitle: "Shuffle Liked Songs",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: PlayRecentlyAddedIntent(),
            phrases: [
                "Play recently added in \(.applicationName)",
                "Play my newest music in \(.applicationName)",
                "Play what's new in \(.applicationName)",
            ],
            shortTitle: "Recently Added",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: StartRadioIntent(),
            phrases: [
                "Start \(\.$seed) radio in \(.applicationName)",
                "Start a station from \(\.$seed) in \(.applicationName)",
                "Play \(\.$seed) radio in \(.applicationName)",
                "Start a station in \(.applicationName)",
                "Start a radio in \(.applicationName)",
            ],
            shortTitle: "Start Radio",
            systemImageName: "dot.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: ResumePlaybackIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Resume music in \(.applicationName)",
                "Continue playing in \(.applicationName)",
            ],
            shortTitle: "Resume",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PausePlaybackIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Pause music in \(.applicationName)",
                "Stop \(.applicationName)",
            ],
            shortTitle: "Pause",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: NextTrackIntent(),
            phrases: [
                "Next song in \(.applicationName)",
                "Skip this song in \(.applicationName)",
                "Skip in \(.applicationName)",
            ],
            shortTitle: "Next Song",
            systemImageName: "forward.fill"
        )
        AppShortcut(
            intent: PreviousTrackIntent(),
            phrases: [
                "Previous song in \(.applicationName)",
                "Go back a song in \(.applicationName)",
            ],
            shortTitle: "Previous Song",
            systemImageName: "backward.fill"
        )
        AppShortcut(
            intent: FavoriteCurrentSongIntent(),
            phrases: [
                "Like this song in \(.applicationName)",
                "Add this song to my favorites in \(.applicationName)",
                "Add the current song to favorites in \(.applicationName)",
                "Favorite this song in \(.applicationName)",
            ],
            shortTitle: "Like Song",
            systemImageName: "heart"
        )
        AppShortcut(
            intent: SetSleepTimerIntent(),
            phrases: [
                "Set a \(\.$length) sleep timer in \(.applicationName)",
                "Set a sleep timer in \(.applicationName)",
                "Start a sleep timer in \(.applicationName)",
            ],
            shortTitle: "Sleep Timer",
            systemImageName: "moon.zzz.fill"
        )
    }
}
