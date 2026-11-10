import Foundation
import JellyampCore

// JellyampCore builds on Linux and has no resource bundle, so the text it
// composes (counts, durations, station titles, fixed error messages) is
// English by default. This file supplies the localized values from the app's
// String Catalog; `JellyampApp.init` installs them before any UI exists.
// Same pattern as `CarPlayStrings.localized`. See docs/LOCALIZATION.md.

extension CoreStrings {
    static var localized: CoreStrings {
        var strings = CoreStrings()
        strings.songCount = { count in
            count == 1 ? String(localized: "1 song") : String(localized: "\(count) songs")
        }
        strings.trackNumber = { number in String(localized: "Track \(number)") }

        strings.spokenHours = { count in String(localized: "\(count) hours") }
        strings.spokenMinutes = { count in String(localized: "\(count) minutes") }
        strings.spokenSeconds = { count in String(localized: "\(count) seconds") }

        strings.approximateSeconds = { seconds in String(localized: "\(seconds) sec") }
        strings.approximateMinutes = { minutes in String(localized: "\(minutes) min") }
        strings.approximateHours = { hours in String(localized: "\(hours) hr") }
        strings.approximateHoursAndMinutes = { hours, minutes in
            String(localized: "\(hours) hr \(minutes) min")
        }

        strings.libraryRadio = String(localized: "Library Radio")
        // Years are passed as text so no locale ever groups them ("1.980").
        strings.decadeTitle = { startYear in
            let decade = String(startYear)
            return String(localized: "\(decade)s")
        }
        strings.decadeShortTitle = { decade in String(localized: "\(decade)s") }

        strings.scrobbleServiceUnreachable = String(localized: "The service could not be reached.")
        strings.lastFMSessionRejected = String(localized: "Last.fm no longer accepts this session. Connect again.")
        strings.lastFMUnavailable = { httpStatus in
            String(localized: "Last.fm is unavailable (HTTP \(httpStatus)).")
        }
        strings.lastFMUnexpectedResponse = String(localized: "Last.fm sent an unexpected response.")
        strings.lastFMNotConnected = String(localized: "Not connected to Last.fm.")
        strings.listenBrainzTokenRejected = String(localized: "ListenBrainz no longer accepts this token.")
        strings.listenBrainzRateLimited = String(localized: "ListenBrainz is rate limiting requests.")
        strings.listenBrainzUnavailable = { httpStatus in
            String(localized: "ListenBrainz is unavailable (HTTP \(httpStatus)).")
        }
        strings.listenBrainzRefused = { httpStatus in
            String(localized: "ListenBrainz refused the listen (HTTP \(httpStatus)).")
        }
        return strings
    }
}

extension EQPreset {
    /// The built-in presets carry English names in Core; unknown IDs (a
    /// preset added later without a translation) fall back to that name.
    var localizedName: String {
        switch id {
        case "flat": return String(localized: "Flat")
        case "bass": return String(localized: "Bass Boost")
        case "treble": return String(localized: "Treble Boost")
        case "vocal": return String(localized: "Vocal")
        case "rock": return String(localized: "Rock")
        case "electronic": return String(localized: "Electronic")
        case "acoustic": return String(localized: "Acoustic")
        case "hiphop": return String(localized: "Hip-Hop")
        case "loudness": return String(localized: "Loudness")
        default: return name
        }
    }
}
