import Foundation

/// One decade of the library, e.g. the 1980s ("Time Travel" stations).
public struct Decade: Codable, Hashable, Identifiable, Comparable, Sendable {
    /// First year of the decade (1980 for the 1980s).
    public let startYear: Int

    /// The decade containing `year` (1987 → 1980s).
    public init(containing year: Int) {
        startYear = year - (((year % 10) + 10) % 10)
    }

    public var id: Int { startYear }
    public var yearRange: ClosedRange<Int> { startYear...(startYear + 9) }

    /// Station seed as the Sonic API expects it (`"1990s"`); the Jellyfin
    /// fallback parses the leading four digits.
    public var seed: String { "\(startYear)s" }

    /// Display label: "1980s".
    public var title: String { seed }

    /// Two-digit form for tight tiles: "80s", "00s".
    public var shortTitle: String {
        let twoDigits = ((startYear % 100) + 100) % 100
        return (twoDigits < 10 ? "0\(twoDigits)" : "\(twoDigits)") + "s"
    }

    public static func < (lhs: Decade, rhs: Decade) -> Bool { lhs.startYear < rhs.startYear }

    /// Distinct decades covered by the given production years, newest first.
    /// Years outside `plausibleYears` are tagging junk (0, 1, 9999) and are
    /// ignored so they don't produce a "0s" station.
    public static func decades(fromYears years: [Int], plausibleYears: ClosedRange<Int> = 1900...2100) -> [Decade] {
        let unique = Set(years.filter(plausibleYears.contains).map { Decade(containing: $0) })
        return unique.sorted(by: >)
    }
}
