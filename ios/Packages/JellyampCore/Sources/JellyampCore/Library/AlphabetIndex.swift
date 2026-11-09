import Foundation

/// A–Z jump index for name-sorted lists.
///
/// Large lists are never loaded completely, so the index cannot scroll to a
/// row that is already there. Instead it resolves a letter to the *server
/// offset* of the first item at or after that letter and the list restarts
/// paging from there.
public enum AlphabetIndex {
    /// Bucket for everything that does not start with a letter.
    public static let symbols = "#"

    public static let letters: [String] = [symbols] + (UnicodeScalar("A").value...UnicodeScalar("Z").value)
        .compactMap { UnicodeScalar($0).map { String(Character($0)) } }

    /// The bucket a name falls into: its first character without diacritics,
    /// upper-cased; `#` for digits, punctuation and non-Latin scripts.
    public static func bucket(for name: String) -> String {
        let folded = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .uppercased()
        guard let first = folded.unicodeScalars.first, first.value >= 65, first.value <= 90 else { return symbols }
        return String(Character(first))
    }

    /// Mirrors how Jellyfin builds sort names (lower-cased, leading article
    /// dropped), for sorting short lists on the client the same way.
    public static func sortKey(for name: String) -> String {
        var key = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        for article in ["the ", "a ", "an "] where key.hasPrefix(article) && key.count > article.count {
            key.removeFirst(article.count)
            break
        }
        return key
    }

    /// Splits an already sorted, fully loaded list into letter sections.
    public static func sections<Item>(_ items: [Item], name: (Item) -> String) -> [(letter: String, items: [Item])] {
        var result: [(letter: String, items: [Item])] = []
        for item in items {
            let letter = bucket(for: sortKey(for: name(item)))
            if let last = result.indices.last, result[last].letter == letter {
                result[last].items.append(item)
            } else {
                result.append((letter, [item]))
            }
        }
        return result
    }

    // MARK: - Server offsets

    /// How the offset of a letter is found on the server.
    public enum OffsetLookup: Equatable, Sendable {
        /// The list starts here.
        case start
        /// Ask for the number of items whose sort name is below this value
        /// (`nameLessThan=…&limit=0` → `TotalRecordCount`). Works for albums
        /// and artists, whose sort names are plain names.
        case countBelow(String)
    }

    public static func offsetLookup(forLetter letter: String) -> OffsetLookup {
        letter == symbols ? .start : .countBelow(letter)
    }

    /// Byte-wise "name sorts before letter", matching the binary collation
    /// Jellyfin uses for `sortBy=Name` (upper case before lower case).
    public static func binaryPrecedes(_ name: String, _ letter: String) -> Bool {
        Array(name.utf8).lexicographicallyPrecedes(Array(letter.utf8))
    }

    /// Lower-bound binary search over a sorted server list that cannot be
    /// filtered by name (songs: their sort name is the track number).
    /// `isBefore(index)` fetches the item at `index` and reports whether it
    /// sorts before the target; about log2(count) probes are made, e.g. 16
    /// single-row requests for 50,000 songs.
    public static func firstIndex(count: Int, isBefore: (Int) async throws -> Bool) async rethrows -> Int {
        var low = 0
        var high = max(0, count)
        while low < high {
            let middle = low + (high - low) / 2
            if try await isBefore(middle) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}
