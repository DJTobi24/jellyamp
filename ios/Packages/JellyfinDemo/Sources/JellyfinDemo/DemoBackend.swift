import Foundation

/// A Jellyfin server in a box: answers the REST calls the app makes from the
/// in-memory `DemoCatalog`. Covers what Jellyamp uses, with the behaviour of
/// Jellyfin 10.10 where the app depends on it (bare array from
/// `/Items/Latest`, `fields=` deciding what list items carry, one entry per
/// track in a playlist, 404 for missing lyrics, …).
///
/// User data — favorites, play counts, playlists — is mutable and lives in
/// memory: every launch starts from the same state, which is what UI tests
/// and screenshots need. Nothing is ever written to disk or sent anywhere.
public final class DemoBackend: @unchecked Sendable {
    struct PlaylistState {
        var id: String
        var name: String
        var entries: [(entryID: String, trackID: String)]
        var created: Int
    }

    let lock = NSLock()
    var favorites: Set<String>
    var playCounts: [String: Int] = [:]
    /// Higher = played more recently.
    var lastPlayed: [String: Int] = [:]
    var playClock = 0
    var playlists: [PlaylistState] = []
    var playlistImages: [String: Data] = [:]
    var playlistCounter = 100
    var entryCounter = 1000
    /// Salt for `sortBy=Random` and station shuffles: every request gets a
    /// different order, every launch the same sequence of orders.
    var shuffleCounter: UInt64 = 0

    public init() {
        favorites = Set(DemoCatalog.favoriteTrackIDs + DemoCatalog.favoriteAlbumIDs + DemoCatalog.favoriteArtistIDs)
        for (rank, entry) in DemoCatalog.recentlyPlayed.reversed().enumerated() {
            playCounts[entry.trackID] = entry.playCount
            lastPlayed[entry.trackID] = rank + 1
        }
        playClock = DemoCatalog.recentlyPlayed.count
        for (index, playlist) in DemoCatalog.playlists.enumerated() {
            let entries = playlist.trackIDs.map { trackID -> (entryID: String, trackID: String) in
                entryCounter += 1
                return (DemoCatalog.id("9", entryCounter), trackID)
            }
            playlists.append(PlaylistState(id: playlist.id, name: playlist.name, entries: entries, created: index))
        }
    }

    // MARK: - Entry point

    public func respond(to request: DemoHTTPRequest) -> DemoHTTPResponse {
        var effective = request
        // HEAD is answered like GET; the transport drops the body.
        if effective.method == "HEAD" { effective.method = "GET" }
        let response: DemoHTTPResponse
        if let media = mediaResponse(effective) {
            response = media
        } else {
            lock.lock()
            response = route(effective)
            lock.unlock()
        }
        return response.applyingRange(request.headers["range"])
    }

    /// Covers and audio are built outside the state lock: rendering a large
    /// cover takes long enough that list requests should not queue behind it.
    private func mediaResponse(_ request: DemoHTTPRequest) -> DemoHTTPResponse? {
        guard request.method == "GET" else { return nil }
        let parts = request.pathComponents
        let lower = parts.map { $0.lowercased() }

        if lower.count >= 4, lower[0] == "items", lower[2] == "images" {
            let itemID = Self.canonical(parts[1])
            guard lower[3] == "primary" else { return .error(404, "Item does not have an image of that type.") }
            lock.lock()
            let uploaded = playlistImages[itemID]
            let exists = playlists.contains { $0.id == itemID } || !itemID.hasPrefix("d")
            lock.unlock()
            if let uploaded {
                return DemoHTTPResponse(status: 200, headers: ["Content-Type": Self.imageContentType(of: uploaded)], body: uploaded)
            }
            let sizes = ["fillWidth", "maxWidth", "width", "fillHeight", "maxHeight", "height"].compactMap { request.integer($0) }
            guard exists, let png = DemoArtwork.png(forItemID: itemID, size: sizes.min() ?? DemoArtwork.defaultSize) else {
                return .error(404, "Item not found.")
            }
            return DemoHTTPResponse(
                status: 200,
                headers: ["Content-Type": "image/png", "Cache-Control": "public, max-age=31536000"],
                body: png
            )
        }

        let audioID: String?
        if lower.count == 3, lower[0] == "items", lower[2] == "file" || lower[2] == "download" {
            audioID = parts[1]
        } else if lower.count == 3, lower[0] == "audio", lower[2] == "universal" || lower[2] == "stream" || lower[2].hasPrefix("stream.") {
            audioID = parts[1]
        } else {
            audioID = nil
        }
        if let audioID {
            guard isAuthorized(request) else { return .error(401, "Unauthorized.") }
            guard let data = DemoAudio.data(forTrackID: Self.canonical(audioID)) else { return .error(404, "Item not found.") }
            return .file(data, contentType: "audio/aac")
        }
        return nil
    }

    // MARK: - Routing (called with the lock held)

    private func route(_ request: DemoHTTPRequest) -> DemoHTTPResponse {
        let parts = request.pathComponents
        let lower = parts.map { $0.lowercased() }
        let method = request.method
        guard let first = lower.first else { return .error(404, "Not found.") }

        // Sonic API (jellyamp-server), with its own key.
        if first == "healthz" { return .json(["status": "ok"]) }
        if first == "api" { return routeSonic(request, lower: lower, parts: parts) }

        // Public Jellyfin routes.
        switch (method, lower) {
        case ("GET", ["system", "info", "public"]):
            return .json(publicSystemInfo())
        case ("GET", ["system", "ping"]), ("POST", ["system", "ping"]):
            return .jsonFragment("\"Jellyfin Server\"")
        case ("POST", ["users", "authenticatebyname"]):
            return authenticate(request)
        case ("GET", ["quickconnect", "enabled"]):
            // The demo has no second device to approve a code on.
            return .jsonFragment("false")
        default:
            break
        }

        guard isAuthorized(request) else { return .error(401, "Unauthorized.") }

        // `/Items/{id}/Similar` and `/InstantMix` also exist per kind
        // (`/Artists/{id}/Similar`, `/Songs/{id}/InstantMix`, …).
        if method == "GET", lower.count == 3,
           ["items", "artists", "albums", "songs", "musicgenres", "playlists"].contains(first) {
            if lower[2] == "similar" { return similar(to: parts[1], request) }
            if lower[2] == "instantmix" { return instantMix(seed: parts[1], request) }
        }

        switch first {
        case "system":
            if method == "GET", lower == ["system", "info"] {
                var info = publicSystemInfo()
                info["OperatingSystem"] = "Demo"
                return .json(info)
            }
        case "users":
            return routeUsers(request, lower: lower, parts: parts)
        case "sessions":
            return routeSessions(request, lower: lower)
        case "items":
            return routeItems(request, lower: lower, parts: parts)
        case "artists":
            // `/Artists` and `/Artists/AlbumArtists`: every demo artist is
            // an album artist.
            if method == "GET", lower.count == 1 || lower == ["artists", "albumartists"] {
                return artistsList(request)
            }
        case "musicgenres":
            if method == "GET", lower.count == 1 { return genresList(request) }
        case "audio":
            if method == "GET", lower.count == 3, lower[2] == "lyrics" { return lyrics(forTrack: parts[1]) }
        case "playlists":
            return routePlaylists(request, lower: lower, parts: parts)
        case "userfavoriteitems":
            if lower.count == 2 { return setFavorite(request, itemID: parts[1]) }
        case "userplayeditems":
            if lower.count == 2 { return .json(userData(for: Self.canonical(parts[1]))) }
        default:
            break
        }
        return .error(404, "Not found.")
    }

    private func routeUsers(_ request: DemoHTTPRequest, lower: [String], parts: [String]) -> DemoHTTPResponse {
        let method = request.method
        if method == "GET", lower.count == 2 {
            // `/Users/Me` and `/Users/{id}`.
            return .json(userJSON())
        }
        // Routes from before 10.9 that the server still answers.
        if lower.count >= 3, lower[2] == "items" {
            var rewritten = request
            rewritten.path = parts.dropFirst(2).joined(separator: "/")
            return routeItems(rewritten, lower: Array(lower.dropFirst(2)), parts: Array(parts.dropFirst(2)))
        }
        if lower.count == 4, lower[2] == "favoriteitems" {
            return setFavorite(request, itemID: parts[3])
        }
        return .error(404, "Not found.")
    }

    private func routeSessions(_ request: DemoHTTPRequest, lower: [String]) -> DemoHTTPResponse {
        guard request.method == "POST" else { return .error(405, "Method not allowed.") }
        if lower == ["sessions", "playing"] {
            // A started playback counts as a play, like on the server.
            if let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
               let itemID = object["ItemId"] as? String {
                let id = Self.canonical(itemID)
                if Self.trackByID[id] != nil {
                    playCounts[id, default: 0] += 1
                    playClock += 1
                    lastPlayed[id] = playClock
                }
            }
            return .noContent
        }
        if lower.count >= 2, ["playing", "logout", "capabilities"].contains(lower[1]) {
            return .noContent
        }
        return .error(404, "Not found.")
    }

    private func routeItems(_ request: DemoHTTPRequest, lower: [String], parts: [String]) -> DemoHTTPResponse {
        let method = request.method
        if lower.count == 1 {
            guard method == "GET" else { return .error(405, "Method not allowed.") }
            return itemsQuery(request)
        }
        if method == "GET", lower == ["items", "latest"] { return latest(request) }
        if method == "GET", lower == ["items", "filters"] { return filters() }
        let itemID = Self.canonical(parts[1])
        if lower.count == 2 {
            switch method {
            case "GET":
                guard let row = allRows().first(where: { $0.id == itemID }) else { return .error(404, "Item not found.") }
                return .json(row.make(Self.allFields))
            case "DELETE":
                guard let index = playlists.firstIndex(where: { $0.id == itemID }) else {
                    // The demo user may not delete library items.
                    return Self.isLibraryItem(itemID) ? .error(403, "Forbidden.") : .error(404, "Item not found.")
                }
                playlists.remove(at: index)
                playlistImages[itemID] = nil
                return .noContent
            default:
                return .error(405, "Method not allowed.")
            }
        }
        if lower.count >= 4, lower[2] == "images", lower[3] == "primary" {
            guard playlists.contains(where: { $0.id == itemID }) else {
                return Self.isLibraryItem(itemID) ? .error(403, "Forbidden.") : .error(404, "Item not found.")
            }
            switch method {
            case "POST":
                // Jellyfin reads an image upload as base64 text.
                guard let image = Data(base64Encoded: request.body, options: [.ignoreUnknownCharacters]), !image.isEmpty else {
                    return .error(400, "Invalid image.")
                }
                playlistImages[itemID] = image
                return .noContent
            case "DELETE":
                playlistImages[itemID] = nil
                return .noContent
            default:
                return .error(405, "Method not allowed.")
            }
        }
        return .error(404, "Not found.")
    }

    // MARK: - Auth and server info

    func isAuthorized(_ request: DemoHTTPRequest) -> Bool {
        let token = DemoCatalog.accessToken
        for name in ["authorization", "x-emby-authorization"] {
            if let header = request.headers[name], header.contains("Token=\"\(token)\"") { return true }
        }
        for name in ["x-emby-token", "x-mediabrowser-token"] where request.headers[name] == token {
            return true
        }
        return request.parameter("api_key") == token || request.parameter("ApiKey") == token
    }

    private func publicSystemInfo() -> [String: Any] {
        [
            "LocalAddress": "http://127.0.0.1",
            "ServerName": DemoCatalog.serverName,
            "Version": DemoCatalog.serverVersion,
            "ProductName": "Jellyfin Server",
            "OperatingSystem": "",
            "Id": DemoCatalog.serverID,
            "StartupWizardCompleted": true,
        ]
    }

    private func userJSON() -> [String: Any] {
        [
            "Name": DemoCatalog.userName,
            "ServerId": DemoCatalog.serverID,
            "Id": DemoCatalog.userID,
            "HasPassword": false,
            "HasConfiguredPassword": false,
            "Policy": ["IsAdministrator": false, "EnableContentDeletion": false, "EnableContentDownloading": true] as [String: Any],
        ]
    }

    private func authenticate(_ request: DemoHTTPRequest) -> DemoHTTPResponse {
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let name = object["Username"] as? String, !name.isEmpty
        else { return .error(400, "Error processing request.") }
        // Any password: there is nothing to protect in the demo.
        return .json([
            "User": userJSON(),
            "AccessToken": DemoCatalog.accessToken,
            "ServerId": DemoCatalog.serverID,
        ] as [String: Any])
    }

    // MARK: - User data

    func userData(for itemID: String) -> [String: Any] {
        let count = playCounts[itemID] ?? 0
        var data: [String: Any] = [
            "PlaybackPositionTicks": 0,
            "PlayCount": count,
            "IsFavorite": favorites.contains(itemID),
            "Played": count > 0,
            "Key": itemID,
            "ItemId": itemID,
        ]
        if let played = lastPlayed[itemID] {
            data["LastPlayedDate"] = Self.dateString(minutesBeforeReference: (playClock - played) * 37)
        }
        return data
    }

    private func setFavorite(_ request: DemoHTTPRequest, itemID rawID: String) -> DemoHTTPResponse {
        let itemID = Self.canonical(rawID)
        guard Self.isLibraryItem(itemID) || playlists.contains(where: { $0.id == itemID }) else {
            return .error(404, "Item not found.")
        }
        switch request.method {
        case "POST": favorites.insert(itemID)
        case "DELETE": favorites.remove(itemID)
        default: return .error(405, "Method not allowed.")
        }
        return .json(userData(for: itemID))
    }

    // MARK: - Lookups

    static let trackByID: [String: DemoCatalog.Track] = Dictionary(uniqueKeysWithValues: DemoCatalog.tracks.map { ($0.id, $0) })
    static let albumByID: [String: DemoCatalog.Album] = Dictionary(uniqueKeysWithValues: DemoCatalog.albums.map { ($0.id, $0) })
    static let artistByID: [String: DemoCatalog.Artist] = Dictionary(uniqueKeysWithValues: DemoCatalog.artists.map { ($0.id, $0) })

    static func isLibraryItem(_ id: String) -> Bool {
        trackByID[id] != nil || albumByID[id] != nil || artistByID[id] != nil
    }

    /// Jellyfin accepts dashed and uppercase GUIDs.
    static func canonical(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func imageContentType(of data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        return "image/jpeg"
    }

    /// The demo's "now": fixed, so dates in responses never change.
    static let referenceDate = Date(timeIntervalSince1970: 1_780_000_000)

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func dateString(minutesBeforeReference minutes: Int) -> String {
        dateFormatter.string(from: referenceDate.addingTimeInterval(-Double(minutes) * 60))
    }
}
