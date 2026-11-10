import Foundation

/// The fictional library the demo backend serves: six artists, twelve albums
/// of five tracks, three playlists. Every name is made up for this app and
/// the audio and artwork are generated (`DemoAudio`, `DemoArtwork`), so the
/// demo ships nothing that belongs to anyone.
///
/// IDs look like Jellyfin's (32 hex digits) and are stable, so tests and
/// screenshots can refer to items: the first digit is the kind (`a` artist,
/// `b` album, `c` track, `d` playlist, `e` genre).
public enum DemoCatalog {
    public struct Artist: Sendable {
        public let id: String
        public let name: String
        public let genre: String
        let overview: String
        let style: DemoAudio.Style
        let palette: DemoArtwork.Palette
    }

    public struct Album: Sendable {
        public let id: String
        public let title: String
        public let artistIndex: Int
        public let year: Int
        let pattern: DemoArtwork.Pattern
        let palette: DemoArtwork.Palette
        /// Position in "recently added" (0 = newest).
        let addedRank: Int

        public var artist: Artist { DemoCatalog.artists[artistIndex] }
        public var genre: String { artist.genre }
    }

    public struct Track: Sendable {
        public let id: String
        public let title: String
        public let albumIndex: Int
        /// 1-based position on the album.
        public let number: Int
        /// Length in audio loops; see `DemoAudio`.
        let loopCount: Int
        /// A second credited artist ("appears on").
        let guestArtistIndex: Int?
        /// Global index, the seed of everything derived per track.
        let ordinal: Int

        public var album: Album { DemoCatalog.albums[albumIndex] }
        public var artist: Artist { album.artist }
        public var duration: TimeInterval { DemoAudio.duration(loopCount: loopCount) }
        var runTimeTicks: Int64 { Int64((duration * 10_000_000).rounded()) }
    }

    public struct Playlist: Sendable {
        public let id: String
        public let name: String
        public let trackIDs: [String]
    }

    public struct Mix: Sendable {
        public let id: String
        public let title: String
        public let description: String
        public let seedTrackIDs: [String]
        public let trackIDs: [String]
    }

    // MARK: - Identity of the demo server

    public static let serverID = "5e000000000000000000000000000001"
    public static let serverName = "Jellyamp Demo"
    /// The Jellyfin version whose behaviour the demo backend imitates.
    public static let serverVersion = "10.10.7"
    public static let userID = "f0000000000000000000000000000001"
    public static let userName = "Demo"
    public static let accessToken = "jellyamp-demo-token"
    /// `X-Api-Key` of the demo's Sonic API.
    public static let sonicAPIKey = "jellyamp-demo-sonic-key"

    // MARK: - Content

    public static let genres = ["Ambient", "Classical", "Electronic", "Folk", "Jazz", "Rock"]

    public static func genreID(_ name: String) -> String? {
        genres.firstIndex(of: name).map { id("e", $0 + 1) }
    }

    public static let artists: [Artist] = [
        Artist(
            id: id("a", 1), name: "Lumen Drift", genre: "Ambient",
            overview: "Lumen Drift is the slow-music project of two former lighthouse keepers. Their records are built from long tape loops, harmonium and the weather outside the studio window.",
            style: .ambient, palette: .init(0x0E3B43, 0x357266, 0xA3BBAD)
        ),
        Artist(
            id: id("a", 2), name: "Neon Estuary", genre: "Electronic",
            overview: "Neon Estuary began in a harbour-side rehearsal room in the mid-eighties and returned decades later with the same drum machine and a much better ferry timetable.",
            style: .electronic, palette: .init(0x2B1055, 0xD53369, 0xFFB86B)
        ),
        Artist(
            id: id("a", 3), name: "The Paper Lanterns", genre: "Folk",
            overview: "Four friends, three guitars and a borrowed bicycle. The Paper Lanterns write small songs about orchards, porches and getting home late.",
            style: .folk, palette: .init(0x5A3E2B, 0xC9853E, 0xF3E3C3)
        ),
        Artist(
            id: id("a", 4), name: "Kite & Compass Trio", genre: "Jazz",
            overview: "Piano, bass and drums, recorded live to two tracks. The Kite & Compass Trio held the same Thursday residency for twelve years.",
            style: .jazz, palette: .init(0x0B132B, 0x3A506B, 0xF2C14E)
        ),
        Artist(
            id: id("a", 5), name: "Velvet Static", genre: "Rock",
            overview: "Velvet Static play loud songs in small rooms. Two guitars, one amplifier that should have been retired years ago.",
            style: .rock, palette: .init(0x1B1B1E, 0xB3001B, 0xE8E9EB)
        ),
        Artist(
            id: id("a", 6), name: "Mira Solène", genre: "Classical",
            overview: "Pianist and composer Mira Solène writes short pieces for upright piano. Her études were recorded in one rainy week.",
            style: .classical, palette: .init(0x22223B, 0x9A8C98, 0xF2E9E4)
        ),
    ]

    public static let albums: [Album] = [
        Album(id: id("b", 1), title: "Tidal Rooms", artistIndex: 0, year: 2021, pattern: .waves, palette: .init(0x0B3954, 0x087E8B, 0xBFD7EA), addedRank: 3),
        Album(id: id("b", 2), title: "Slow Weather", artistIndex: 0, year: 2018, pattern: .rings, palette: .init(0x2F4858, 0x86BBD8, 0xF6F5AE), addedRank: 9),
        Album(id: id("b", 3), title: "Night Ferry", artistIndex: 1, year: 2023, pattern: .sun, palette: .init(0x1A0B3B, 0xE0218A, 0xFFC857), addedRank: 1),
        Album(id: id("b", 4), title: "Chrome Sunsets", artistIndex: 1, year: 1986, pattern: .stripes, palette: .init(0x3D0E61, 0xFF6B6B, 0x4ECDC4), addedRank: 7),
        Album(id: id("b", 5), title: "Letters to the Orchard", artistIndex: 2, year: 2016, pattern: .dots, palette: .init(0x606C38, 0xDDA15E, 0xFEFAE0), addedRank: 10),
        Album(id: id("b", 6), title: "Small Hours", artistIndex: 2, year: 2019, pattern: .mountains, palette: .init(0x283618, 0xBC6C25, 0xFAEDCD), addedRank: 5),
        Album(id: id("b", 7), title: "Blue Hour Sessions", artistIndex: 3, year: 1962, pattern: .rings, palette: .init(0x03045E, 0x0077B6, 0xFFD166), addedRank: 6),
        Album(id: id("b", 8), title: "Second Set", artistIndex: 3, year: 1974, pattern: .stripes, palette: .init(0x14213D, 0xFCA311, 0xE5E5E5), addedRank: 11),
        Album(id: id("b", 9), title: "Loud Rooms", artistIndex: 4, year: 1994, pattern: .dots, palette: .init(0x0D0D0D, 0xD00000, 0xFFBA08), addedRank: 8),
        Album(id: id("b", 10), title: "Afterglow Motel", artistIndex: 4, year: 2008, pattern: .sun, palette: .init(0x2D1E2F, 0xF72585, 0x4CC9F0), addedRank: 2),
        Album(id: id("b", 11), title: "Études for Rain", artistIndex: 5, year: 2020, pattern: .waves, palette: .init(0x2B2D42, 0x8D99AE, 0xEDF2F4), addedRank: 4),
        Album(id: id("b", 12), title: "Nocturnes in Glass", artistIndex: 5, year: 2024, pattern: .mountains, palette: .init(0x10002B, 0x7B2CBF, 0xE0AAFF), addedRank: 0),
    ]

    private static let trackTitles: [[String]] = [
        ["Low Tide Lanterns", "Salt on the Windows", "Rooms Below the Pier", "Undertow Lullaby", "Morning, Slowly"],
        ["Barometer", "A Field Guide to Fog", "First Snow, Last Bus", "Static in the Pines", "Thaw"],
        ["Departure Board", "Night Ferry", "Harbour Lights at 2 a.m.", "Tape Deck Heart", "Last Stop: Sunrise"],
        ["Chrome Sunsets", "Arcade Summer", "Parallel Lines of Light", "Runaway Signal", "Midnight Mileage"],
        ["Apple Wood", "Letters to the Orchard", "Borrowed Bicycle", "The Long Way Round", "Porchlight"],
        ["Kettle Song", "Small Hours", "Moth and Moon", "Pocketful of Maps", "Goodnight, Lighthouse"],
        ["Blue Hour", "Dog-Eared Pages", "Second Cup", "Rain on Fourth Street", "One for the Doorman"],
        ["Second Set", "Loose Change", "Velvet Rope Waltz", "Half Past Late", "Closing Tab"],
        ["Feedback Garden", "Loud Rooms", "Paper Crown", "Engine Idle", "Tuesday Was a Riot"],
        ["Afterglow Motel", "Vacancy Sign", "Neon Postcard", "Room 12", "Checkout Time"],
        ["Étude No. 1 “Drizzle”", "Étude No. 2 “Gutters”", "Étude No. 3 “Umbrellas”", "Étude No. 4 “Petrichor”", "Étude No. 5 “Clearing”"],
        ["Nocturne I", "Nocturne II (Streetlamp)", "Interlude for an Open Window", "Nocturne III", "Nocturne IV (Dawn)"],
    ]

    /// (album index, track number) → guest artist index.
    private static let guests: [Int: Int] = [
        2 * 10 + 4: 5,   // "Tape Deck Heart" features Mira Solène
        5 * 10 + 3: 0,   // "Moth and Moon" features Lumen Drift
        9 * 10 + 2: 1,   // "Vacancy Sign" features Neon Estuary
    ]

    public static let tracks: [Track] = {
        var result: [Track] = []
        for (albumIndex, titles) in trackTitles.enumerated() {
            for (offset, title) in titles.enumerated() {
                let ordinal = albumIndex * 5 + offset
                // 2:00 … 4:20, fixed per track.
                let loops = 30 + Int(DemoRandom.hash(UInt64(ordinal) &+ 77) % 36)
                result.append(Track(
                    id: id("c", (albumIndex + 1) * 100 + offset + 1),
                    title: title,
                    albumIndex: albumIndex,
                    number: offset + 1,
                    loopCount: loops,
                    guestArtistIndex: guests[albumIndex * 10 + offset + 1],
                    ordinal: ordinal
                ))
            }
        }
        return result
    }()

    public static func track(album: Int, number: Int) -> Track {
        tracks[album * 5 + number - 1]
    }

    public static let playlists: [Playlist] = [
        Playlist(id: id("d", 1), name: "Sunday Morning, Slowly", trackIDs: pick([(0, 5), (5, 1), (10, 1), (4, 5), (1, 5), (11, 3), (5, 5), (0, 1)])),
        Playlist(id: id("d", 2), name: "Late Drive", trackIDs: pick([(2, 2), (3, 5), (9, 1), (2, 3), (8, 4), (3, 2), (9, 3), (2, 5), (8, 1)])),
        Playlist(id: id("d", 3), name: "Keys After Midnight", trackIDs: pick([(6, 1), (11, 1), (7, 3), (10, 4), (6, 4), (11, 2), (7, 5)])),
    ]

    public static let mixes: [Mix] = [
        Mix(id: "mix-demo-1", title: "Ambient Mix", description: "Based on Lumen Drift, Mira Solène and more",
            seedTrackIDs: pick([(0, 1), (10, 3)]),
            trackIDs: pick([(0, 1), (10, 3), (1, 2), (11, 4), (0, 4), (5, 3), (1, 4), (10, 5), (0, 3), (11, 1), (1, 1), (10, 2)])),
        Mix(id: "mix-demo-2", title: "Electronic Mix", description: "Based on Neon Estuary and Velvet Static",
            seedTrackIDs: pick([(2, 1), (3, 2)]),
            trackIDs: pick([(2, 1), (3, 2), (2, 4), (9, 2), (3, 4), (2, 2), (9, 3), (3, 1), (2, 5), (3, 3), (8, 2), (2, 3)])),
        Mix(id: "mix-demo-3", title: "Jazz Mix", description: "Based on Kite & Compass Trio and The Paper Lanterns",
            seedTrackIDs: pick([(6, 2), (7, 1)]),
            trackIDs: pick([(6, 2), (7, 1), (4, 3), (6, 5), (7, 4), (5, 4), (6, 3), (7, 2), (4, 1), (6, 1), (11, 3), (7, 5)])),
        Mix(id: "mix-demo-4", title: "Rock Mix", description: "Based on Velvet Static and Neon Estuary",
            seedTrackIDs: pick([(8, 2), (9, 1)]),
            trackIDs: pick([(8, 2), (9, 1), (8, 5), (9, 4), (3, 4), (8, 3), (9, 5), (8, 1), (4, 4), (9, 2), (8, 4), (3, 1)])),
    ]

    // MARK: - Initial user data

    static let favoriteTrackIDs = pick([(0, 1), (2, 2), (4, 2), (6, 1), (8, 2), (10, 1), (11, 2), (5, 5), (3, 1)])
    static let favoriteAlbumIDs = [albums[0].id, albums[2].id, albums[6].id, albums[11].id]
    static let favoriteArtistIDs = [artists[0].id, artists[3].id]

    /// Most recent first, with the play count of each.
    static let recentlyPlayed: [(trackID: String, playCount: Int)] = [
        (track(album: 2, number: 2).id, 14), (track(album: 11, number: 1).id, 6), (track(album: 0, number: 1).id, 21),
        (track(album: 6, number: 1).id, 9), (track(album: 9, number: 1).id, 4), (track(album: 4, number: 2).id, 12),
        (track(album: 10, number: 1).id, 7), (track(album: 2, number: 4).id, 5), (track(album: 8, number: 2).id, 11),
        (track(album: 5, number: 2).id, 3), (track(album: 0, number: 4).id, 8), (track(album: 7, number: 1).id, 2),
    ]

    /// Synced lyrics (seconds, line). Written for the demo.
    static let lyrics: [String: [(start: Double, text: String)]] = [
        track(album: 2, number: 2).id: [
            (0.5, "The last boat leaves at half past ten"),
            (4.5, "Harbour lights, and then again"),
            (8.5, "Your name in neon on the tide"),
            (12.5, "I keep the window seat inside"),
            (16.5, "Night ferry, carry me"),
            (20.5, "Slow across the sleeping sea"),
            (24.5, "Every wave a kilometre"),
            (28.5, "Closer to the morning, nearer"),
            (32.5, "The engine hums a lullaby"),
            (36.5, "Gulls asleep against the sky"),
            (40.5, "Night ferry, carry me"),
            (44.5, "Home is where the lights will be"),
        ],
        track(album: 4, number: 2).id: [
            (0.5, "Dear orchard, it is nearly spring"),
            (4.5, "The ladders lean, the blackbirds sing"),
            (8.5, "I wrote to you from every town"),
            (12.5, "And folded all the letters down"),
            (16.5, "Keep an apple on the bough for me"),
            (20.5, "Keep the gate from swinging free"),
            (24.5, "I'll be home when the blossoms land"),
            (28.5, "With an envelope in either hand"),
        ],
        track(album: 0, number: 1).id: [
            (1.0, "Low tide"),
            (9.0, "Lanterns on the water"),
            (17.0, "Wait for me"),
            (25.0, "Low tide"),
        ],
    ]

    /// Plain (unsynced) lyrics.
    static let plainLyrics: [String: [String]] = [
        track(album: 9, number: 1).id: [
            "Checked in under someone else's name",
            "The sign says vacancy, the sign's to blame",
            "Afterglow motel, pink light on the wall",
            "I only came to make a single call",
        ],
    ]

    // MARK: - Helpers

    static func id(_ kind: String, _ number: Int) -> String {
        let digits = String(number)
        return kind + String(repeating: "0", count: 32 - kind.count - digits.count) + digits
    }

    private static func pick(_ positions: [(Int, Int)]) -> [String] {
        positions.map { track(album: $0.0, number: $0.1).id }
    }
}

/// Deterministic pseudo-randomness: the demo must look the same on every
/// launch (screenshots, UI tests).
enum DemoRandom {
    /// SplitMix64 finalizer.
    static func hash(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        return hash(value)
    }

    /// In 0 ..< 1.
    static func unit(_ value: UInt64) -> Double {
        Double(hash(value) >> 11) / Double(UInt64(1) << 53)
    }
}
