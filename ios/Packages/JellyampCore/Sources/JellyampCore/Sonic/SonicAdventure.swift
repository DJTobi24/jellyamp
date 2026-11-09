import Foundation

/// A Sonic Adventure request: a path of tracks from `start` to `end`.
/// Validated here so the view only renders the outcome.
public struct AdventureRequest: Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case missingStart
        case missingEnd
        case sameTrack
    }

    /// Waypoints between the two endpoints the user may choose from.
    public static let allowedSteps: ClosedRange<Int> = 5...50
    public static let stepChoices: [Int] = [5, 10, 15, 20, 30, 40, 50]
    public static let defaultSteps = 15

    public let startID: String
    public let endID: String
    public let steps: Int

    public init(startID: String, endID: String, steps: Int) {
        self.startID = startID
        self.endID = endID
        self.steps = Self.clamp(steps: steps)
    }

    public static func clamp(steps: Int) -> Int {
        min(max(steps, allowedSteps.lowerBound), allowedSteps.upperBound)
    }

    /// Builds a request from the picker state, or says what is missing.
    public static func validate(startID: String?, endID: String?, steps: Int) -> Result<AdventureRequest, ValidationError> {
        guard let startID, !startID.isEmpty else { return .failure(.missingStart) }
        guard let endID, !endID.isEmpty else { return .failure(.missingEnd) }
        guard startID != endID else { return .failure(.sameTrack) }
        return .success(AdventureRequest(startID: startID, endID: endID, steps: steps))
    }

    /// Total tracks in the resulting path, endpoints included.
    public var expectedTrackCount: Int { steps + 2 }
}

public enum AdventurePath {
    /// Normalizes the provider's path: drops repeated IDs (keeping the first
    /// occurrence) and makes sure the chosen endpoints frame the path even
    /// if the server omitted or moved them.
    public static func normalizedIDs(_ ids: [String], request: AdventureRequest) -> [String] {
        var seen: Set<String> = [request.startID, request.endID]
        var middle: [String] = []
        for id in ids where seen.insert(id).inserted {
            middle.append(id)
        }
        return [request.startID] + middle + [request.endID]
    }

    /// Orders resolved tracks along the path. IDs the library could not
    /// resolve (deleted since analysis) are skipped.
    public static func orderedTracks(_ tracks: [Track], alongIDs ids: [String]) -> [Track] {
        SimilarRanking.ordered(tracks, byIDs: ids)
    }

    /// Default playlist name: "Adventure: Start → End".
    public static func defaultPlaylistName(start: Track, end: Track) -> String {
        "Adventure: \(start.title) \u{2192} \(end.title)"
    }

    public static func totalDuration(of tracks: [Track]) -> TimeInterval {
        tracks.reduce(0) { $0 + $1.duration }
    }
}
