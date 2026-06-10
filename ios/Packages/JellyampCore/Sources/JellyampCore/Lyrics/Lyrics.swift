import Foundation

/// One line of (optionally synced) lyrics.
public struct LyricLine: Codable, Equatable, Sendable {
    /// Seconds from track start; nil for unsynced lyrics.
    public var start: TimeInterval?
    public var text: String

    public init(start: TimeInterval? = nil, text: String) {
        self.start = start
        self.text = text
    }
}

/// Parses LRC-style timestamped lyrics text into lines.
public enum LyricsParser {
    /// Matches `[mm:ss.xx]` (also `[mm:ss]` and hour-less variants).
    public static func parse(lrc text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            var remainder = line[...]
            var timestamps: [TimeInterval] = []
            while remainder.hasPrefix("["), let close = remainder.firstIndex(of: "]") {
                let tag = remainder[remainder.index(after: remainder.startIndex)..<close]
                if let time = parseTimestamp(String(tag)) {
                    timestamps.append(time)
                    remainder = remainder[remainder.index(after: close)...]
                } else {
                    break
                }
            }
            let content = remainder.trimmingCharacters(in: .whitespaces)
            if timestamps.isEmpty {
                // Metadata tags like [ar:…] are skipped; bare text becomes unsynced.
                if !content.isEmpty && !line.hasPrefix("[") {
                    lines.append(LyricLine(text: content))
                }
            } else {
                for time in timestamps {
                    lines.append(LyricLine(start: time, text: content))
                }
            }
        }
        return lines.sorted { ($0.start ?? 0) < ($1.start ?? 0) }
    }

    private static func parseTimestamp(_ tag: String) -> TimeInterval? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else {
            return nil
        }
        return minutes * 60 + seconds
    }
}

/// Binary-search lookup of the active lyric line during playback.
public struct LyricsTimeline: Equatable, Sendable {
    public let lines: [LyricLine]
    public var isSynced: Bool { lines.contains { $0.start != nil } }

    public init(lines: [LyricLine]) {
        self.lines = lines.sorted { ($0.start ?? 0) < ($1.start ?? 0) }
    }

    /// Index of the line active at `time`, or nil before the first line.
    public func activeLineIndex(at time: TimeInterval) -> Int? {
        guard isSynced else { return nil }
        var low = 0
        var high = lines.count - 1
        var result: Int?
        while low <= high {
            let mid = (low + high) / 2
            if (lines[mid].start ?? 0) <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}
