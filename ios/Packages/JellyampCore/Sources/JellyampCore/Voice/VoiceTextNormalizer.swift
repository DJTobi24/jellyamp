import Foundation

/// Normalizes spoken queries and library titles into a comparable form.
///
/// Speech recognition hands us text that differs from library metadata in
/// predictable ways: no diacritics ("Bjork"), no punctuation ("ACDC",
/// "REM"), "and" for "&", and a dropped leading article ("Beatles"). Both
/// sides go through the same folding so those differences disappear before
/// scoring.
public enum VoiceTextNormalizer {
    /// Leading articles ignored when they are followed by more words. English
    /// plus the languages most common in music libraries; applied to both
    /// sides, so over-stripping is harmless ("Die Antwoord" still matches).
    static let leadingArticles: Set<String> = [
        "the", "a", "an", "der", "die", "das", "le", "la", "les", "el", "los", "las",
    ]

    /// Letters `folding(.diacriticInsensitive)` leaves alone because they are
    /// distinct letters rather than base + combining mark.
    private static let letterReplacements: [(String, String)] = [
        ("ß", "ss"), ("æ", "ae"), ("œ", "oe"), ("ø", "o"), ("đ", "d"), ("ð", "d"), ("ł", "l"), ("þ", "th"),
    ]

    /// Lowercased, diacritic-free words of `text`, punctuation removed.
    /// Apostrophes vanish ("Don't" → "dont") instead of splitting the word,
    /// because dictation drops them inconsistently.
    public static func words(_ text: String) -> [String] {
        var folded = text.lowercased()
        for (letter, replacement) in letterReplacements {
            folded = folded.replacingOccurrences(of: letter, with: replacement)
        }
        folded = folded.folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: nil)

        var words: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        for character in folded {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if character == "'" || character == "’" || character == "`" || character == "." {
                // Joiners: "don't" → "dont", "R.E.M." → "rem".
                continue
            } else if character == "&" || character == "+" {
                flush()
                words.append("and")
            } else {
                flush()
            }
        }
        flush()
        return words
    }

    /// Words with a leading article removed (unless nothing would remain).
    public static func significantWords(_ text: String) -> [String] {
        let all = words(text)
        if all.count > 1, let first = all.first, leadingArticles.contains(first) {
            return Array(all.dropFirst())
        }
        return all
    }

    /// Canonical comparison key: significant words joined by single spaces.
    public static func normalize(_ text: String) -> String {
        significantWords(text).joined(separator: " ")
    }

    /// The key with spaces removed, so "AC/DC" and a dictated "ACDC" agree.
    public static func compact(_ text: String) -> String {
        significantWords(text).joined()
    }

    /// The title without trailing edition noise — "Abbey Road (Remastered
    /// 2019)", "Kind of Blue [Legacy Edition]", "Hurt - Live" — which nobody
    /// says out loud. Returns the input when nothing would remain.
    public static func strippingEditionSuffix(_ title: String) -> String {
        var result = title
        for opener in ["(", "["] {
            if let range = result.range(of: opener) {
                result = String(result[result.startIndex..<range.lowerBound])
            }
        }
        if let range = result.range(of: " - ") {
            result = String(result[result.startIndex..<range.lowerBound])
        }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return words(trimmed).isEmpty ? title : trimmed
    }

    /// Sort/index key for alphabetical browsing: the first significant
    /// character, uppercased; "#" for digits and symbols.
    public static func indexLetter(_ text: String) -> String {
        guard let first = compact(text).first, first.isLetter else { return "#" }
        return String(first).uppercased()
    }
}
