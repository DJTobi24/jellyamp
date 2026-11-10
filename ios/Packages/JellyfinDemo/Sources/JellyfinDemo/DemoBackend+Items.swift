import Foundation

/// The `/Items` family: one flat table of everything in the library that the
/// query parameters filter, sort and page — the way Jellyfin answers them.
extension DemoBackend {
    enum Kind: String {
        case audio = "Audio"
        case album = "MusicAlbum"
        case artist = "MusicArtist"
        case playlist = "Playlist"
    }

    struct Row {
        var kind: Kind
        var id: String
        var name: String
        var sortName: String
        var album = ""
        var albumID: String?
        var albumArtist = ""
        var albumArtistID: String?
        /// Everyone credited: the album artist plus guests.
        var artistIDs: [String] = []
        var artist = ""
        var genres: [String] = []
        var year = 0
        /// Minutes before the reference date the item was added.
        var addedMinutesAgo = 0
        var runtime: Int64 = 0
        var disc = 0
        var index = 0
        /// Builds the JSON item; the argument is the lowercased `fields` set.
        var make: (Set<String>) -> [String: Any]
    }

    static let allFields: Set<String> = ["mediasources", "genres", "datecreated", "parentid", "overview", "childcount"]

    // MARK: - Rows

    func allRows() -> [Row] {
        var rows: [Row] = []
        rows.reserveCapacity(DemoCatalog.tracks.count + DemoCatalog.albums.count + DemoCatalog.artists.count + playlists.count)
        for track in DemoCatalog.tracks { rows.append(row(for: track)) }
        for album in DemoCatalog.albums { rows.append(row(for: album)) }
        for artist in DemoCatalog.artists { rows.append(row(for: artist)) }
        for playlist in playlists { rows.append(row(for: playlist)) }
        return rows
    }

    private static func addedMinutes(_ album: DemoCatalog.Album) -> Int {
        (album.addedRank * 9 + 2) * 24 * 60
    }

    /// Jellyfin's sort name drops a leading article.
    private static func sortName(_ name: String) -> String {
        let lowered = name.lowercased()
        for article in ["the ", "a ", "an "] where lowered.hasPrefix(article) {
            return String(name.dropFirst(article.count))
        }
        return name
    }

    private static func credits(of track: DemoCatalog.Track) -> [DemoCatalog.Artist] {
        var credits = [track.artist]
        if let guest = track.guestArtistIndex { credits.append(DemoCatalog.artists[guest]) }
        return credits
    }

    func row(for track: DemoCatalog.Track) -> Row {
        let album = track.album
        let credits = Self.credits(of: track)
        let number = String(track.number)
        return Row(
            kind: .audio,
            id: track.id,
            name: track.title,
            // Audio items sort by track number first ("0001 - Title").
            sortName: String(repeating: "0", count: 4 - number.count) + number + " - " + track.title,
            album: album.title,
            albumID: album.id,
            albumArtist: album.artist.name,
            albumArtistID: album.artist.id,
            artistIDs: credits.map(\.id),
            artist: credits[0].name,
            genres: [album.genre],
            year: album.year,
            addedMinutesAgo: Self.addedMinutes(album) - track.number,
            runtime: track.runTimeTicks,
            disc: 1,
            index: track.number,
            make: { [unowned self] fields in self.trackJSON(track, fields: fields) }
        )
    }

    func row(for album: DemoCatalog.Album) -> Row {
        let tracks = DemoCatalog.tracks.filter { $0.album.id == album.id }
        var artistIDs = [album.artist.id]
        for track in tracks {
            for credit in Self.credits(of: track) where !artistIDs.contains(credit.id) {
                artistIDs.append(credit.id)
            }
        }
        return Row(
            kind: .album,
            id: album.id,
            name: album.title,
            sortName: Self.sortName(album.title),
            album: album.title,
            albumID: album.id,
            albumArtist: album.artist.name,
            albumArtistID: album.artist.id,
            artistIDs: artistIDs,
            artist: album.artist.name,
            genres: [album.genre],
            year: album.year,
            addedMinutesAgo: Self.addedMinutes(album),
            runtime: tracks.reduce(0) { $0 + $1.runTimeTicks },
            make: { [unowned self] fields in self.albumJSON(album, tracks: tracks, artistIDs: artistIDs, fields: fields) }
        )
    }

    func row(for artist: DemoCatalog.Artist) -> Row {
        let albums = DemoCatalog.albums.filter { $0.artist.id == artist.id }
        return Row(
            kind: .artist,
            id: artist.id,
            name: artist.name,
            sortName: Self.sortName(artist.name),
            albumArtist: artist.name,
            albumArtistID: artist.id,
            artistIDs: [artist.id],
            artist: artist.name,
            genres: [artist.genre],
            addedMinutesAgo: albums.map(Self.addedMinutes).max() ?? 0,
            make: { [unowned self] fields in self.artistJSON(artist, fields: fields) }
        )
    }

    func row(for playlist: PlaylistState) -> Row {
        let runtime = playlist.entries.reduce(Int64(0)) { $0 + (Self.trackByID[$1.trackID]?.runTimeTicks ?? 0) }
        return Row(
            kind: .playlist,
            id: playlist.id,
            name: playlist.name,
            sortName: playlist.name,
            // Playlists created in the app are the newest items.
            addedMinutesAgo: playlist.created >= 100 ? -playlist.created : (playlist.created + 1) * 3 * 24 * 60,
            runtime: runtime,
            make: { [unowned self] fields in self.playlistJSON(id: playlist.id, fields: fields) }
        )
    }

    // MARK: - JSON items

    private static func nameID(_ artist: DemoCatalog.Artist) -> [String: Any] {
        ["Name": artist.name, "Id": artist.id]
    }

    private static func genreItems(_ genres: [String]) -> [[String: Any]] {
        genres.map { ["Name": $0, "Id": DemoCatalog.genreID($0) ?? ""] }
    }

    func trackJSON(_ track: DemoCatalog.Track, fields: Set<String>, playlistEntryID: String? = nil) -> [String: Any] {
        let album = track.album
        let credits = Self.credits(of: track)
        var item: [String: Any] = [
            "Name": track.title,
            "ServerId": DemoCatalog.serverID,
            "Id": track.id,
            "Type": "Audio",
            "MediaType": "Audio",
            "IsFolder": false,
            "Container": "aac",
            "HasLyrics": DemoCatalog.lyrics[track.id] != nil || DemoCatalog.plainLyrics[track.id] != nil,
            "RunTimeTicks": track.runTimeTicks,
            "ProductionYear": album.year,
            "IndexNumber": track.number,
            "ParentIndexNumber": 1,
            "Album": album.title,
            "AlbumId": album.id,
            "AlbumPrimaryImageTag": DemoArtwork.tag(forItemID: album.id),
            "AlbumArtist": album.artist.name,
            "AlbumArtists": [Self.nameID(album.artist)],
            "Artists": credits.map(\.name),
            "ArtistItems": credits.map(Self.nameID),
            "ImageTags": [String: String](),
            "BackdropImageTags": [String](),
            "LocationType": "FileSystem",
            "NormalizationGain": Self.normalizationGain(of: track),
            "UserData": userData(for: track.id),
        ]
        if fields.contains("genres") {
            item["Genres"] = [album.genre]
            item["GenreItems"] = Self.genreItems([album.genre])
        }
        if fields.contains("datecreated") {
            item["DateCreated"] = Self.dateString(minutesBeforeReference: Self.addedMinutes(album) - track.number)
        }
        if fields.contains("parentid") {
            item["ParentId"] = album.id
        }
        if fields.contains("mediasources") {
            let bitrate = DemoAudio.bitrate(of: track)
            item["MediaSources"] = [[
                "Protocol": "File",
                "Id": track.id,
                "Type": "Default",
                "Container": "aac",
                "Size": DemoAudio.byteCount(of: track),
                "Name": track.title,
                "IsRemote": false,
                "RunTimeTicks": track.runTimeTicks,
                "SupportsTranscoding": true,
                "SupportsDirectStream": true,
                "SupportsDirectPlay": true,
                "Bitrate": bitrate,
                "DefaultAudioStreamIndex": 0,
                "MediaStreams": [[
                    "Codec": "aac",
                    "Profile": "LC",
                    "Type": "Audio",
                    "Index": 0,
                    "ChannelLayout": "stereo",
                    "Channels": DemoAudio.channels,
                    "SampleRate": DemoAudio.sampleRate,
                    "BitRate": bitrate,
                    "IsDefault": true,
                    "DisplayTitle": "AAC - Stereo - Default",
                ] as [String: Any]],
            ] as [String: Any]]
        }
        if let playlistEntryID {
            item["PlaylistItemId"] = playlistEntryID
        }
        return item
    }

    /// Jellyfin's `NormalizationGain`: what brings the track to -18 LUFS.
    static func normalizationGain(of track: DemoCatalog.Track) -> Double {
        let gain = -18 - Self.integratedLoudness(of: track)
        return (gain * 10).rounded() / 10
    }

    /// Stand-in for a measured loudness, fixed per track.
    static func integratedLoudness(of track: DemoCatalog.Track) -> Double {
        -20 + 6 * DemoRandom.unit(UInt64(track.ordinal) &+ 900)
    }

    func albumJSON(_ album: DemoCatalog.Album, tracks: [DemoCatalog.Track], artistIDs: [String], fields: Set<String>) -> [String: Any] {
        let credited = artistIDs.compactMap { Self.artistByID[$0] }
        var item: [String: Any] = [
            "Name": album.title,
            "ServerId": DemoCatalog.serverID,
            "Id": album.id,
            "Type": "MusicAlbum",
            "MediaType": "Unknown",
            "IsFolder": true,
            "RunTimeTicks": tracks.reduce(Int64(0)) { $0 + $1.runTimeTicks },
            "ProductionYear": album.year,
            "AlbumArtist": album.artist.name,
            "AlbumArtists": [Self.nameID(album.artist)],
            "Artists": credited.map(\.name),
            "ArtistItems": credited.map(Self.nameID),
            "ImageTags": ["Primary": DemoArtwork.tag(forItemID: album.id)],
            "BackdropImageTags": [String](),
            "LocationType": "FileSystem",
            "NormalizationGain": -1.5,
            "UserData": userData(for: album.id),
        ]
        if fields.contains("genres") {
            item["Genres"] = [album.genre]
            item["GenreItems"] = Self.genreItems([album.genre])
        }
        if fields.contains("datecreated") {
            item["DateCreated"] = Self.dateString(minutesBeforeReference: Self.addedMinutes(album))
        }
        if fields.contains("childcount") {
            item["ChildCount"] = tracks.count
        }
        return item
    }

    func artistJSON(_ artist: DemoCatalog.Artist, fields: Set<String>) -> [String: Any] {
        var item: [String: Any] = [
            "Name": artist.name,
            "ServerId": DemoCatalog.serverID,
            "Id": artist.id,
            "Type": "MusicArtist",
            "MediaType": "Unknown",
            "IsFolder": true,
            "ImageTags": ["Primary": DemoArtwork.tag(forItemID: artist.id)],
            "BackdropImageTags": [String](),
            "LocationType": "FileSystem",
            "UserData": userData(for: artist.id),
        ]
        if fields.contains("genres") {
            item["Genres"] = [artist.genre]
            item["GenreItems"] = Self.genreItems([artist.genre])
        }
        if fields.contains("overview") {
            item["Overview"] = artist.overview
        }
        return item
    }

    func playlistJSON(id: String, fields: Set<String>) -> [String: Any] {
        guard let playlist = playlists.first(where: { $0.id == id }) else { return ["Id": id, "Type": "Playlist"] }
        // An uploaded cover gets its own tag, so image caches let go of the
        // generated one.
        let tag = playlistImages[id].map { DemoArtwork.tag(forItemID: "\(id):\($0.count)") } ?? DemoArtwork.tag(forItemID: id)
        var item: [String: Any] = [
            "Name": playlist.name,
            "ServerId": DemoCatalog.serverID,
            "Id": playlist.id,
            "Type": "Playlist",
            "MediaType": "Audio",
            "IsFolder": true,
            "RunTimeTicks": playlist.entries.reduce(Int64(0)) { $0 + (Self.trackByID[$1.trackID]?.runTimeTicks ?? 0) },
            "ImageTags": ["Primary": tag],
            "BackdropImageTags": [String](),
            "LocationType": "FileSystem",
            "UserData": userData(for: playlist.id),
        ]
        if fields.contains("childcount") {
            item["ChildCount"] = playlist.entries.count
        }
        return item
    }

    // MARK: - GET /Items

    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    }

    func fields(of request: DemoHTTPRequest) -> Set<String> {
        Set(request.list("fields").map { $0.lowercased() })
    }

    func itemsQuery(_ request: DemoHTTPRequest) -> DemoHTTPResponse {
        let ids = request.parameter("ids").map { _ in
            request.list("ids").map(Self.canonical).filter { $0.count == 32 && $0.allSatisfy(\.isHexDigit) }
        }
        let types = Set(request.list("includeItemTypes").compactMap { name in
            [Kind.audio, .album, .artist, .playlist].first { $0.rawValue.lowercased() == name.lowercased() }
        })
        var rows = allRows()
        if let ids {
            // (An unparsable `ids` makes the real server answer the user's
            // root folders; the demo has none, so that is an empty list.)
            let wanted = Set(ids)
            rows = rows.filter { wanted.contains($0.id) }
            if !types.isEmpty { rows = rows.filter { types.contains($0.kind) } }
        } else {
            // Without `ids` or a type this is the root-folder listing.
            guard !types.isEmpty else { return page(rows: [], request: request) }
            rows = rows.filter { types.contains($0.kind) }
        }
        rows = filtered(rows, by: request)
        rows = sorted(rows, by: request, defaultKey: ids == nil ? "sortname" : nil)
        if let ids, request.parameter("sortBy") == nil {
            // Keep the order that was asked for.
            let position = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            rows.sort { (position[$0.id] ?? 0) < (position[$1.id] ?? 0) }
        }
        return page(rows: rows, request: request)
    }

    func filtered(_ rows: [Row], by request: DemoHTTPRequest) -> [Row] {
        var rows = rows
        let albumIDs = Set(request.list("albumIds").map(Self.canonical))
        if !albumIDs.isEmpty {
            rows = rows.filter { $0.kind == .audio && albumIDs.contains($0.albumID ?? "") }
        }
        if let parentID = request.parameter("parentId").map(Self.canonical), Self.albumByID[parentID] != nil {
            rows = rows.filter { $0.kind == .audio && $0.albumID == parentID }
        }
        let albumArtistIDs = Set(request.list("albumArtistIds").map(Self.canonical))
        if !albumArtistIDs.isEmpty {
            rows = rows.filter { albumArtistIDs.contains($0.albumArtistID ?? "") }
        }
        let artistIDs = Set(request.list("artistIds").map(Self.canonical))
        if !artistIDs.isEmpty {
            rows = rows.filter { !artistIDs.isDisjoint(with: $0.artistIDs) }
        }
        // Credited, but not as the album artist.
        let contributingIDs = Set(request.list("contributingArtistIds").map(Self.canonical))
        if !contributingIDs.isEmpty {
            rows = rows.filter { !contributingIDs.isDisjoint(with: $0.artistIDs) && !contributingIDs.contains($0.albumArtistID ?? "") }
        }
        let genreIDs = Set(request.list("genreIds").map(Self.canonical))
        if !genreIDs.isEmpty {
            rows = rows.filter { row in row.genres.contains { genreIDs.contains(DemoCatalog.genreID($0) ?? "") } }
        }
        // `genres` takes names, pipe-delimited.
        let genreNames = Set(request.list("genres", separator: "|").map(Self.fold))
        if !genreNames.isEmpty {
            rows = rows.filter { row in row.genres.contains { genreNames.contains(Self.fold($0)) } }
        }
        let years = Set(request.list("years").compactMap { Int($0) })
        if !years.isEmpty {
            rows = rows.filter { years.contains($0.year) }
        }
        let filters = Set(request.list("filters").map { $0.lowercased() })
        if filters.contains("isfavorite") || request.flag("isFavorite") == true {
            rows = rows.filter { favorites.contains($0.id) }
        }
        if filters.contains("isplayed") {
            rows = rows.filter { (playCounts[$0.id] ?? 0) > 0 }
        }
        if filters.contains("isunplayed") {
            rows = rows.filter { (playCounts[$0.id] ?? 0) == 0 }
        }
        if let term = request.parameter("searchTerm").map(Self.fold), !term.isEmpty {
            rows = rows.filter { Self.fold($0.name).contains(term) }
        }
        if let bound = request.parameter("nameLessThan").map(Self.fold) {
            rows = rows.filter { Self.fold($0.sortName) < bound }
        }
        if let bound = request.parameter("nameStartsWithOrGreater").map(Self.fold) {
            rows = rows.filter { Self.fold($0.sortName) >= bound }
        }
        if let prefix = request.parameter("nameStartsWith").map(Self.fold) {
            rows = rows.filter { Self.fold($0.sortName).hasPrefix(prefix) }
        }
        return rows
    }

    /// Applies `sortBy` / `sortOrder` (parallel comma lists; the last order
    /// repeats for the remaining keys).
    func sorted(_ rows: [Row], by request: DemoHTTPRequest, defaultKey: String?) -> [Row] {
        var keys = request.list("sortBy").map { $0.lowercased() }
        if keys.isEmpty, let defaultKey { keys = [defaultKey] }
        guard !keys.isEmpty else { return rows }
        let orders = request.list("sortOrder").map { $0.lowercased() == "descending" }
        shuffleCounter += 1
        let salt = shuffleCounter

        enum Value {
            case text(String)
            case number(Int64)
        }
        func value(_ row: Row, _ key: String) -> Value {
            switch key {
            case "name": return .text(Self.fold(row.name))
            case "album": return .text(Self.fold(row.album))
            case "albumartist": return .text(Self.fold(row.albumArtist))
            case "artist": return .text(Self.fold(row.artist))
            case "productionyear", "premieredate": return .number(Int64(row.year))
            // Newer = larger, so "Descending" lists the newest first.
            case "datecreated": return .number(Int64(-row.addedMinutesAgo))
            case "dateplayed": return .number(Int64(lastPlayed[row.id] ?? 0))
            case "playcount": return .number(Int64(playCounts[row.id] ?? 0))
            case "runtime": return .number(row.runtime)
            case "parentindexnumber": return .number(Int64(row.disc))
            case "indexnumber": return .number(Int64(row.index))
            case "random": return .number(Int64(bitPattern: DemoRandom.hash(DemoRandom.hash(row.id) &+ salt) >> 1))
            default: return .text(Self.fold(row.sortName))
            }
        }
        // Precomputed: the comparator runs many times per row.
        let keyed = rows.map { row in (row, keys.map { value(row, $0) }) }
        let ordered = keyed.sorted { lhs, rhs in
            for index in keys.indices {
                let descending = index < orders.count ? orders[index] : (orders.last ?? false)
                switch (lhs.1[index], rhs.1[index]) {
                case (.text(let a), .text(let b)):
                    if a != b { return descending ? a > b : a < b }
                case (.number(let a), .number(let b)):
                    if a != b { return descending ? a > b : a < b }
                default:
                    break
                }
            }
            return lhs.0.id < rhs.0.id
        }
        return ordered.map(\.0)
    }

    /// `startIndex` / `limit` and the `{ Items, TotalRecordCount }` envelope.
    func page(rows: [Row], request: DemoHTTPRequest, fields: Set<String>? = nil) -> DemoHTTPResponse {
        let fields = fields ?? self.fields(of: request)
        let start = min(max(request.integer("startIndex") ?? 0, 0), rows.count)
        let limit = request.integer("limit").map { max($0, 0) } ?? rows.count
        let slice = rows[start..<min(start + limit, rows.count)]
        let countTotal = request.flag("enableTotalRecordCount") ?? true
        return .json([
            "Items": slice.map { $0.make(fields) },
            "TotalRecordCount": countTotal ? rows.count : 0,
            "StartIndex": start,
        ] as [String: Any])
    }

    // MARK: - Other list endpoints

    /// `/Items/Latest`: a bare array, newest albums first.
    func latest(_ request: DemoHTTPRequest) -> DemoHTTPResponse {
        let fields = self.fields(of: request)
        let limit = max(request.integer("limit") ?? 20, 0)
        let albums = DemoCatalog.albums.sorted { $0.addedRank < $1.addedRank }.prefix(limit)
        let items = albums.map { album -> [String: Any] in
            var item = row(for: album).make(fields)
            // Like the server: no usable child count here.
            if item["ChildCount"] != nil { item["ChildCount"] = 0 }
            return item
        }
        return .json(items)
    }

    func filters() -> DemoHTTPResponse {
        .json([
            "Genres": DemoCatalog.genres,
            "Tags": [String](),
            "OfficialRatings": [String](),
            "Years": Array(Set(DemoCatalog.albums.map(\.year))).sorted(),
        ] as [String: Any])
    }

    func artistsList(_ request: DemoHTTPRequest) -> DemoHTTPResponse {
        var rows = DemoCatalog.artists.map { row(for: $0) }
        rows = filtered(rows, by: request)
        rows = sorted(rows, by: request, defaultKey: "sortname")
        return page(rows: rows, request: request)
    }

    func genresList(_ request: DemoHTTPRequest) -> DemoHTTPResponse {
        var names = DemoCatalog.genres
        if let term = request.parameter("searchTerm").map(Self.fold), !term.isEmpty {
            names = names.filter { Self.fold($0).contains(term) }
        }
        let start = min(max(request.integer("startIndex") ?? 0, 0), names.count)
        let limit = request.integer("limit").map { max($0, 0) } ?? names.count
        let items = names[start..<min(start + limit, names.count)].map { name -> [String: Any] in
            [
                "Name": name,
                "ServerId": DemoCatalog.serverID,
                "Id": DemoCatalog.genreID(name) ?? "",
                "Type": "MusicGenre",
                "ImageTags": [String: String](),
                "BackdropImageTags": [String](),
                "LocationType": "FileSystem",
                "MediaType": "Unknown",
            ]
        }
        return .json(["Items": items, "TotalRecordCount": names.count, "StartIndex": start] as [String: Any])
    }

    /// `/Items/{id}/Similar`: same kind as the seed, same genre first.
    func similar(to rawID: String, _ request: DemoHTTPRequest) -> DemoHTTPResponse {
        let seedID = Self.canonical(rawID)
        let limit = max(request.integer("limit") ?? 12, 0)
        let candidates: [Row]
        let seedGenre: String
        if let artist = Self.artistByID[seedID] {
            seedGenre = artist.genre
            candidates = DemoCatalog.artists.filter { $0.id != seedID }.map { row(for: $0) }
        } else if let album = Self.albumByID[seedID] {
            seedGenre = album.genre
            candidates = DemoCatalog.albums.filter { $0.id != seedID }.map { row(for: $0) }
        } else if Self.trackByID[seedID] != nil || playlists.contains(where: { $0.id == seedID }) {
            // Jellyfin has no similarity for single tracks.
            return .json(["Items": [Any](), "TotalRecordCount": 0, "StartIndex": 0] as [String: Any])
        } else {
            return .error(404, "Item not found.")
        }
        let ranked = candidates.sorted { lhs, rhs in
            let left = Self.genreDistance(lhs.genres.first ?? "", seedGenre)
            let right = Self.genreDistance(rhs.genres.first ?? "", seedGenre)
            return left != right ? left < right : lhs.name < rhs.name
        }
        let items = ranked.prefix(limit).map { $0.make(fields(of: request)) }
        return .json(["Items": items, "TotalRecordCount": items.count, "StartIndex": 0] as [String: Any])
    }

    /// How far apart two genres sound, 0 … 1 (see `sonicPosition`).
    static func genreDistance(_ lhs: String, _ rhs: String) -> Double {
        abs((genrePositions[lhs] ?? 0.5) - (genrePositions[rhs] ?? 0.5))
    }

    /// The demo's one-dimensional "sound space": calm on the left, loud on
    /// the right. Also what the Sonic API endpoints rank by.
    static let genrePositions: [String: Double] = [
        "Ambient": 0.05, "Classical": 0.22, "Folk": 0.42, "Jazz": 0.58, "Electronic": 0.78, "Rock": 0.95,
    ]

    /// `/Items/{id}/InstantMix`: the seed's tracks first, then what sounds
    /// closest, in a fixed pseudo-random order.
    func instantMix(seed rawID: String, _ request: DemoHTTPRequest) -> DemoHTTPResponse {
        let seedID = Self.canonical(rawID)
        let limit = max(request.integer("limit") ?? 200, 0)
        var seedTracks: [DemoCatalog.Track]
        if let track = Self.trackByID[seedID] {
            seedTracks = [track]
        } else if Self.albumByID[seedID] != nil {
            seedTracks = DemoCatalog.tracks.filter { $0.album.id == seedID }
        } else if Self.artistByID[seedID] != nil {
            seedTracks = DemoCatalog.tracks.filter { $0.artist.id == seedID }
        } else if let playlist = playlists.first(where: { $0.id == seedID }) {
            seedTracks = playlist.entries.compactMap { Self.trackByID[$0.trackID] }
        } else if let genre = DemoCatalog.genres.first(where: { DemoCatalog.genreID($0) == seedID }) {
            seedTracks = DemoCatalog.tracks.filter { $0.album.genre == genre }
        } else {
            return .error(404, "Item not found.")
        }
        guard let anchor = seedTracks.first else {
            return .json(["Items": [Any](), "TotalRecordCount": 0, "StartIndex": 0] as [String: Any])
        }
        if Self.trackByID[seedID] == nil {
            // For a collection, a few of its own tracks lead the mix.
            seedTracks = Array(seedTracks.prefix(3))
        }
        let seedIDs = Set(seedTracks.map(\.id))
        let salt = DemoRandom.hash(seedID)
        let others = DemoCatalog.tracks.filter { !seedIDs.contains($0.id) }.sorted { lhs, rhs in
            let left = Self.sonicDistance(lhs, anchor) + 0.25 * DemoRandom.unit(salt &+ UInt64(lhs.ordinal))
            let right = Self.sonicDistance(rhs, anchor) + 0.25 * DemoRandom.unit(salt &+ UInt64(rhs.ordinal))
            return left < right
        }
        let fields = self.fields(of: request)
        let items = (seedTracks + others).prefix(limit).map { trackJSON($0, fields: fields) }
        return .json(["Items": items, "TotalRecordCount": items.count, "StartIndex": 0] as [String: Any])
    }

    func lyrics(forTrack rawID: String) -> DemoHTTPResponse {
        let trackID = Self.canonical(rawID)
        guard Self.trackByID[trackID] != nil else { return .error(404, "Item not found.") }
        let lines: [[String: Any]]
        if let synced = DemoCatalog.lyrics[trackID] {
            lines = synced.map { ["Text": $0.text, "Start": Int64($0.start * 10_000_000)] }
        } else if let plain = DemoCatalog.plainLyrics[trackID] {
            lines = plain.map { ["Text": $0] }
        } else {
            return .error(404, "Lyrics not found.")
        }
        return .json(["Metadata": [String: Any](), "Lyrics": lines] as [String: Any])
    }

    // MARK: - Playlists

    func routePlaylists(_ request: DemoHTTPRequest, lower: [String], parts: [String]) -> DemoHTTPResponse {
        let method = request.method
        if lower.count == 1 {
            guard method == "POST" else { return .error(405, "Method not allowed.") }
            return createPlaylist(request)
        }
        let playlistID = Self.canonical(parts[1])
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else {
            return .error(404, "Playlist not found.")
        }
        if lower.count == 2 {
            switch method {
            case "GET":
                return .json(playlistJSON(id: playlistID, fields: Self.allFields))
            case "POST":
                return updatePlaylist(at: index, request)
            default:
                return .error(405, "Method not allowed.")
            }
        }
        if lower.count == 3, lower[2] == "items" {
            switch method {
            case "GET":
                let fields = self.fields(of: request)
                let entries = playlists[index].entries
                let start = min(max(request.integer("startIndex") ?? 0, 0), entries.count)
                let limit = request.integer("limit").map { max($0, 0) } ?? entries.count
                let items = entries[start..<min(start + limit, entries.count)].compactMap { entry -> [String: Any]? in
                    Self.trackByID[entry.trackID].map { trackJSON($0, fields: fields, playlistEntryID: entry.entryID) }
                }
                return .json(["Items": items, "TotalRecordCount": entries.count, "StartIndex": start] as [String: Any])
            case "POST":
                append(request.list("ids").map(Self.canonical), toPlaylistAt: index)
                return .noContent
            case "DELETE":
                let entryIDs = Set(request.list("entryIds"))
                playlists[index].entries.removeAll { entryIDs.contains($0.entryID) }
                return .noContent
            default:
                return .error(405, "Method not allowed.")
            }
        }
        if lower.count == 6, lower[2] == "items", lower[4] == "move", method == "POST" {
            guard let from = playlists[index].entries.firstIndex(where: { $0.entryID == parts[3] }),
                  let target = Int(parts[5]), target >= 0
            else { return .error(404, "Playlist item not found.") }
            let entry = playlists[index].entries.remove(at: from)
            playlists[index].entries.insert(entry, at: min(target, playlists[index].entries.count))
            return .noContent
        }
        return .error(404, "Not found.")
    }

    /// Jellyfin 10.10 keeps a track once per playlist.
    private func append(_ trackIDs: [String], toPlaylistAt index: Int) {
        for trackID in trackIDs where Self.trackByID[trackID] != nil {
            guard !playlists[index].entries.contains(where: { $0.trackID == trackID }) else { continue }
            entryCounter += 1
            playlists[index].entries.append((DemoCatalog.id("9", entryCounter), trackID))
        }
    }

    private func createPlaylist(_ request: DemoHTTPRequest) -> DemoHTTPResponse {
        let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        let name = (object?["Name"] as? String) ?? request.parameter("name") ?? ""
        let ids = (object?["Ids"] as? [String]) ?? request.list("ids")
        guard !name.isEmpty else { return .error(400, "Error processing request.") }
        playlistCounter += 1
        let id = DemoCatalog.id("d", playlistCounter)
        playlists.append(PlaylistState(id: id, name: name, entries: [], created: playlistCounter))
        append(ids.map(Self.canonical), toPlaylistAt: playlists.count - 1)
        return .json(["Id": id])
    }

    /// `POST /Playlists/{id}`: rename and/or replace the contents.
    private func updatePlaylist(at index: Int, _ request: DemoHTTPRequest) -> DemoHTTPResponse {
        guard let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
            return .error(400, "Error processing request.")
        }
        if let name = object["Name"] as? String, !name.isEmpty {
            playlists[index].name = name
        }
        if let ids = object["Ids"] as? [String] {
            let existing = playlists[index].entries
            playlists[index].entries = []
            for trackID in ids.map(Self.canonical) where Self.trackByID[trackID] != nil {
                // An entry keeps its ID when its track stays in the playlist.
                if let kept = existing.first(where: { $0.trackID == trackID }) {
                    if !playlists[index].entries.contains(where: { $0.entryID == kept.entryID }) {
                        playlists[index].entries.append(kept)
                    }
                } else {
                    append([trackID], toPlaylistAt: index)
                }
            }
        }
        return .noContent
    }
}
