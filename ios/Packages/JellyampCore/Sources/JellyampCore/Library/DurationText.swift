import Foundation

/// Duration strings for rows, headers and VoiceOver. One place, so "3:05"
/// looks the same on every screen and never shows "0:60" or garbage for the
/// NaN / negative values an unprobed track can carry.
public enum DurationText {
    private static func wholeSeconds(_ duration: TimeInterval) -> Int {
        guard duration.isFinite, duration > 0 else { return 0 }
        // Round first: 59.6 s must become 1:00, not 0:60 or 0:59.
        return Int(min(duration.rounded(), 359_999))
    }

    /// Track-row style: `3:05`, `1:02:03`.
    public static func clock(_ duration: TimeInterval) -> String {
        let total = wholeSeconds(duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return "\(hours):\(pad(minutes)):\(pad(seconds))"
        }
        return "\(minutes):\(pad(seconds))"
    }

    /// Header style for a whole album or playlist: `45 sec`, `38 min`,
    /// `1 hr 12 min`. Seconds are dropped once a minute is reached.
    public static func approximate(_ duration: TimeInterval) -> String {
        let total = wholeSeconds(duration)
        let strings = CoreStrings.current
        if total < 60 { return strings.approximateSeconds(total) }
        // Round to the nearest minute so 59:40 reads "1 hr", not "59 min".
        let totalMinutes = (total + 30) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return strings.approximateMinutes(minutes) }
        if minutes == 0 { return strings.approximateHours(hours) }
        return strings.approximateHoursAndMinutes(hours, minutes)
    }

    /// Spelled out for VoiceOver, which reads "3:05" as a time of day:
    /// `3 minutes, 5 seconds`.
    public static func spoken(_ duration: TimeInterval) -> String {
        let total = wholeSeconds(duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        let strings = CoreStrings.current
        var parts: [String] = []
        if hours > 0 { parts.append(strings.spokenHours(hours)) }
        if minutes > 0 { parts.append(strings.spokenMinutes(minutes)) }
        if seconds > 0 || parts.isEmpty { parts.append(strings.spokenSeconds(seconds)) }
        return parts.joined(separator: ", ")
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
