import Foundation

/// Time-of-day bucket behind the Home greeting ("Good morning", …).
public enum HomeGreeting: String, CaseIterable, Sendable {
    case morning
    case afternoon
    case evening
    case night

    /// Buckets by local hour (0–23). Late night counts from 22:00 until the
    /// early morning so a 01:00 session isn't greeted with "Good morning".
    public static func bucket(forHour hour: Int) -> HomeGreeting {
        let normalized = ((hour % 24) + 24) % 24
        switch normalized {
        case 5..<12: return .morning
        case 12..<18: return .afternoon
        case 18..<22: return .evening
        default: return .night
        }
    }

    public static func bucket(for date: Date, calendar: Calendar = .current) -> HomeGreeting {
        bucket(forHour: calendar.component(.hour, from: date))
    }
}
