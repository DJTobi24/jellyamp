import Foundation

/// The user-facing phrases Core composes itself: counts, durations, the
/// titles of generated stations and the fixed scrobbling error messages.
///
/// Core has no resource bundle (it must build and test on Linux without
/// Apple's localization APIs), so it only knows the English defaults below.
/// The app shell installs localized values once at launch
/// (`CoreStrings.current = .localized`); everything in Core reads
/// `CoreStrings.current` at the moment it builds a string. `CarPlayStrings`
/// follows the same idea for the CarPlay lists.
public struct CoreStrings: Sendable {
    /// "1 song" / "12 songs".
    public var songCount: @Sendable (Int) -> String = { CoreStrings.englishPlural($0, "song") }
    /// VoiceOver prefix of a numbered row: "Track 3".
    public var trackNumber: @Sendable (Int) -> String = { "Track \($0)" }

    /// Spelled-out duration parts for VoiceOver: "1 hour", "5 minutes".
    public var spokenHours: @Sendable (Int) -> String = { CoreStrings.englishPlural($0, "hour") }
    public var spokenMinutes: @Sendable (Int) -> String = { CoreStrings.englishPlural($0, "minute") }
    public var spokenSeconds: @Sendable (Int) -> String = { CoreStrings.englishPlural($0, "second") }

    /// Header-style durations: "45 sec", "38 min", "1 hr", "1 hr 12 min".
    public var approximateSeconds: @Sendable (Int) -> String = { "\($0) sec" }
    public var approximateMinutes: @Sendable (Int) -> String = { "\($0) min" }
    public var approximateHours: @Sendable (Int) -> String = { "\($0) hr" }
    public var approximateHoursAndMinutes: @Sendable (_ hours: Int, _ minutes: Int) -> String = { "\($0) hr \($1) min" }

    /// Title of the whole-library station.
    public var libraryRadio = "Library Radio"
    /// Decade label from its first year: 1980 → "1980s".
    public var decadeTitle: @Sendable (_ startYear: Int) -> String = { "\($0)s" }
    /// Decade label for tight tiles from its two digits: "80" → "80s".
    public var decadeShortTitle: @Sendable (_ twoDigits: String) -> String = { "\($0)s" }

    /// Scrobbling problems shown in the settings ("Last error").
    public var scrobbleServiceUnreachable = "The service could not be reached."
    public var lastFMSessionRejected = "Last.fm no longer accepts this session. Connect again."
    public var lastFMUnavailable: @Sendable (_ httpStatus: Int) -> String = { "Last.fm is unavailable (HTTP \($0))." }
    public var lastFMUnexpectedResponse = "Last.fm sent an unexpected response."
    public var lastFMNotConnected = "Not connected to Last.fm."
    public var listenBrainzTokenRejected = "ListenBrainz no longer accepts this token."
    public var listenBrainzRateLimited = "ListenBrainz is rate limiting requests."
    public var listenBrainzUnavailable: @Sendable (_ httpStatus: Int) -> String = { "ListenBrainz is unavailable (HTTP \($0))." }
    public var listenBrainzRefused: @Sendable (_ httpStatus: Int) -> String = { "ListenBrainz refused the listen (HTTP \($0))." }

    public init() {}

    private static func englishPlural(_ count: Int, _ unit: String) -> String {
        count == 1 ? "1 \(unit)" : "\(count) \(unit)s"
    }

    // MARK: - Installed values

    private static let lock = NSLock()
    private static var installed = CoreStrings()

    /// The strings Core uses right now. Set once at app launch, before any
    /// UI is built; reads are cheap and safe from any thread.
    public static var current: CoreStrings {
        get {
            lock.lock()
            defer { lock.unlock() }
            return installed
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            installed = newValue
        }
    }
}
