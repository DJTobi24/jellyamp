import Foundation

/// The Sonic API (docs/SONIC-API.md) on top of the demo library, so demo
/// mode also shows what the optional jellyamp-server adds: Mixes for You,
/// sonically similar tracks, Sonic Adventure, stations and loudness.
///
/// There is no audio analysis here. "Similarity" is a made-up position per
/// track — its genre on a calm-to-loud axis plus a fixed offset — which is
/// enough for results that look plausible and never change.
extension DemoBackend {
    static func sonicPosition(of track: DemoCatalog.Track) -> (x: Double, y: Double) {
        let base = genrePositions[track.album.genre] ?? 0.5
        let x = base + (DemoRandom.unit(UInt64(track.ordinal) &+ 300) - 0.5) * 0.12
        let y = DemoRandom.unit(UInt64(track.ordinal) &+ 600)
        return (x, y)
    }

    private static func distance(_ lhs: (x: Double, y: Double), _ rhs: (x: Double, y: Double)) -> Double {
        let dx = lhs.x - rhs.x
        let dy = (lhs.y - rhs.y) * 0.3
        return (dx * dx + dy * dy).squareRoot()
    }

    static func sonicDistance(_ lhs: DemoCatalog.Track, _ rhs: DemoCatalog.Track) -> Double {
        distance(sonicPosition(of: lhs), sonicPosition(of: rhs))
    }

    private static func centroid(of tracks: [DemoCatalog.Track]) -> (x: Double, y: Double) {
        guard !tracks.isEmpty else { return (0.5, 0.5) }
        let positions = tracks.map(sonicPosition)
        return (positions.reduce(0) { $0 + $1.x } / Double(tracks.count), positions.reduce(0) { $0 + $1.y } / Double(tracks.count))
    }

    private static func detail(_ status: Int, _ message: String) -> DemoHTTPResponse {
        .json(["detail": message], status: status)
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }

    func routeSonic(_ request: DemoHTTPRequest, lower: [String], parts: [String]) -> DemoHTTPResponse {
        guard lower.count >= 3, lower[1] == "v1" else { return Self.detail(404, "Not Found") }
        guard request.headers["x-api-key"] == DemoCatalog.sonicAPIKey else {
            return Self.detail(401, "Invalid or missing API key")
        }
        let method = request.method
        switch lower[2] {
        case "info" where method == "GET":
            return .json(sonicInfo())
        case "scan" where method == "POST":
            return .json(["started": false, "scan": sonicScan()] as [String: Any], status: 202)
        case "similar" where method == "GET" && lower.count == 5:
            return sonicSimilar(kind: lower[3], id: Self.canonical(parts[4]), request)
        case "adventure" where method == "GET":
            return sonicAdventure(request)
        case "mixes" where method == "GET":
            let mixes = DemoCatalog.mixes.map { mix -> [String: Any] in
                [
                    "id": mix.id,
                    "title": mix.title,
                    "description": mix.description,
                    "seedItemIds": mix.seedTrackIDs,
                    "itemIds": mix.trackIDs,
                ]
            }
            return .json(["mixes": mixes])
        case "stations" where method == "POST":
            return sonicStation(request)
        case "loudness" where method == "GET" && lower.count == 4:
            guard let track = Self.trackByID[Self.canonical(parts[3])] else { return Self.detail(404, "Track is not analyzed") }
            return .json([
                "integratedLufs": Self.rounded(Self.integratedLoudness(of: track)),
                "truePeak": Self.rounded(-1.5 + DemoRandom.unit(UInt64(track.ordinal) &+ 1200)),
            ])
        case "sage" where method == "POST":
            return Self.detail(409, "Sonic Sage is not enabled on this server")
        default:
            return Self.detail(404, "Not Found")
        }
    }

    private func sonicScan() -> [String: Any] {
        [
            "state": "idle",
            "startedAt": Self.dateString(minutesBeforeReference: 190),
            "finishedAt": Self.dateString(minutesBeforeReference: 180),
            "tracksPending": 0,
            "tracksFailed": 0,
            "lastError": NSNull(),
        ]
    }

    private func sonicInfo() -> [String: Any] {
        [
            "version": "1.1",
            "jellyfinServerId": DemoCatalog.serverID,
            "tracksTotal": DemoCatalog.tracks.count,
            "tracksAnalyzed": DemoCatalog.tracks.count,
            "capabilities": ["similar", "adventure", "mixes", "stations", "loudness"],
            "analysis": ["backend": "dsp", "version": "1"],
            "scan": sonicScan(),
        ]
    }

    private func sonicSimilar(kind: String, id: String, _ request: DemoHTTPRequest) -> DemoHTTPResponse {
        var ranked: [(id: String, distance: Double)]
        let defaultLimit: Int
        switch kind {
        case "tracks":
            guard let seed = Self.trackByID[id] else { return Self.detail(404, "Track is not analyzed") }
            let excludeSameAlbum = request.flag("excludeSameAlbum") ?? false
            ranked = DemoCatalog.tracks
                .filter { $0.id != id && !(excludeSameAlbum && $0.album.id == seed.album.id) }
                .map { ($0.id, Self.sonicDistance($0, seed)) }
            defaultLimit = 50
        case "artists":
            guard Self.artistByID[id] != nil else { return Self.detail(404, "Artist is not analyzed") }
            let seed = Self.centroid(of: DemoCatalog.tracks.filter { $0.artist.id == id })
            ranked = DemoCatalog.artists.filter { $0.id != id }.map { artist in
                (artist.id, Self.distance(Self.centroid(of: DemoCatalog.tracks.filter { $0.artist.id == artist.id }), seed))
            }
            defaultLimit = 20
        case "albums":
            guard Self.albumByID[id] != nil else { return Self.detail(404, "Album is not analyzed") }
            let seed = Self.centroid(of: DemoCatalog.tracks.filter { $0.album.id == id })
            ranked = DemoCatalog.albums.filter { $0.id != id }.map { album in
                (album.id, Self.distance(Self.centroid(of: DemoCatalog.tracks.filter { $0.album.id == album.id }), seed))
            }
            defaultLimit = 20
        default:
            return Self.detail(404, "Not Found")
        }
        let limit = request.integer("limit") ?? defaultLimit
        guard (1...500).contains(limit) else { return .json(["detail": [["msg": "limit out of range"]]], status: 422) }
        ranked.sort { $0.distance != $1.distance ? $0.distance < $1.distance : $0.id < $1.id }
        let items = ranked.prefix(limit).map { ["itemId": $0.id, "distance": Self.rounded($0.distance)] as [String: Any] }
        return .json(["items": items])
    }

    private func sonicAdventure(_ request: DemoHTTPRequest) -> DemoHTTPResponse {
        guard let fromID = request.parameter("from").map(Self.canonical),
              let toID = request.parameter("to").map(Self.canonical),
              fromID != toID
        else { return .json(["detail": [["msg": "from and to must be two different tracks"]]], status: 422) }
        let steps = request.integer("steps") ?? 20
        guard (1...200).contains(steps) else { return .json(["detail": [["msg": "steps out of range"]]], status: 422) }
        guard let from = Self.trackByID[fromID], let to = Self.trackByID[toID] else {
            return Self.detail(404, "Track is not analyzed")
        }
        let start = Self.sonicPosition(of: from)
        let end = Self.sonicPosition(of: to)
        var used: Set<String> = [fromID, toID]
        var items: [[String: Any]] = [["itemId": fromID, "position": 0, "distance": 0.0]]
        for step in 1...steps {
            let t = Double(step) / Double(steps + 1)
            let waypoint = (x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            let candidates = DemoCatalog.tracks.filter { !used.contains($0.id) }
            guard let nearest = candidates.min(by: {
                Self.distance(Self.sonicPosition(of: $0), waypoint) < Self.distance(Self.sonicPosition(of: $1), waypoint)
            }) else { break }
            used.insert(nearest.id)
            items.append([
                "itemId": nearest.id,
                "position": items.count,
                "distance": Self.rounded(Self.distance(Self.sonicPosition(of: nearest), waypoint)),
            ])
        }
        items.append(["itemId": toID, "position": items.count, "distance": 0.0])
        return .json(["items": items])
    }

    private func sonicStation(_ request: DemoHTTPRequest) -> DemoHTTPResponse {
        guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
              let type = object["type"] as? String, let seed = object["seed"] as? String
        else { return .json(["detail": [["msg": "type and seed are required"]]], status: 422) }
        let count = (object["count"] as? Int) ?? 100
        guard (1...500).contains(count) else { return .json(["detail": [["msg": "count out of range"]]], status: 422) }

        var matches: [DemoCatalog.Track]
        switch type {
        case "genre", "style":
            let wanted = Self.fold(seed)
            matches = DemoCatalog.tracks.filter { Self.fold($0.album.genre) == wanted }
        case "decade":
            guard let first = Int(seed.prefix(4)) else { return Self.detail(404, "Unknown decade") }
            matches = DemoCatalog.tracks.filter { (first...(first + 9)).contains($0.album.year) }
        case "mood":
            guard let anchor = Self.trackByID[Self.canonical(seed)] else { return Self.detail(404, "Track is not analyzed") }
            matches = DemoCatalog.tracks
                .sorted { Self.sonicDistance($0, anchor) < Self.sonicDistance($1, anchor) }
                .prefix(24)
                .map { $0 }
        default:
            return .json(["detail": [["msg": "unknown station type"]]], status: 422)
        }
        guard !matches.isEmpty else { return Self.detail(404, "No analyzed track matches the seed") }
        // Stations are shuffled: a different order on every request.
        shuffleCounter += 1
        let salt = shuffleCounter
        matches.sort { DemoRandom.hash(UInt64($0.ordinal) &* 31 &+ salt) < DemoRandom.hash(UInt64($1.ordinal) &* 31 &+ salt) }
        return .json(["itemIds": matches.prefix(count).map(\.id)])
    }
}
