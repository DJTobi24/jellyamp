import XCTest
import JellyfinBackend
import JellyampCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Live integration tests: the whole JellyfinBackend API surface against a
// real Jellyfin server holding the synthetic library from
// `scripts/dev-jellyfin/` (start one with `scripts/dev-jellyfin/up.sh`).
//
// Enabled by JELLYFIN_TEST_URL / JELLYFIN_TEST_USER / JELLYFIN_TEST_PASSWORD;
// without them every test is skipped, so a plain `swift test` stays hermetic.
// The tests only create what they delete again (playlists, favorites, one
// played mark) and never touch library items, so they can share a server.

// MARK: - The library `scripts/dev-jellyfin/make-library.py` generates

struct AlbumSpec {
    var artist: String
    var title: String
    var year: Int
    var genre: String
    var container: String
    var codec: String
    var tracks: [String]
}

enum Library {
    /// Keep in sync with `ALBUMS` in make-library.py (same order: it is the
    /// order the files are created in, i.e. the "recently added" order).
    static let albums: [AlbumSpec] = [
        AlbumSpec(artist: "Aurora Drift", title: "Low Tide", year: 1994, genre: "Ambient", container: "flac", codec: "flac",
                  tracks: ["Harbour Lights", "Slow Water", "Tidal Sleep", "Morning Fog"]),
        AlbumSpec(artist: "Aurora Drift", title: "Night Maps", year: 2003, genre: "Ambient", container: "mp3", codec: "mp3",
                  tracks: ["Polaris", "Dead Reckoning", "Meridian"]),
        AlbumSpec(artist: "Neon Circuit", title: "Voltage", year: 2016, genre: "Electronic", container: "mp3", codec: "mp3",
                  tracks: ["Power On", "Gridlock", "Arc Flash", "Standby", "Overclock"]),
        AlbumSpec(artist: "Neon Circuit", title: "Afterimage", year: 2021, genre: "Electronic", container: "m4a", codec: "aac",
                  tracks: ["Phosphor", "Persistence", "Scanline"]),
        AlbumSpec(artist: "The Granite Saints", title: "Quarry Songs", year: 1978, genre: "Rock", container: "mp3", codec: "mp3",
                  tracks: ["Blast Line", "Hard Hat Blues", "Gravel Road", "Dust and Diesel"]),
        AlbumSpec(artist: "The Granite Saints", title: "Second Shift", year: 1985, genre: "Rock", container: "flac", codec: "flac",
                  tracks: ["Clock In", "Overtime", "Last Bus Home"]),
        AlbumSpec(artist: "Halden Quartet", title: "Chamber Works", year: 1962, genre: "Classical", container: "flac", codec: "flac",
                  tracks: ["Allegro in D", "Adagio", "Scherzo", "Finale"]),
        AlbumSpec(artist: "Blue Hour Trio", title: "Kind of Late", year: 1959, genre: "Jazz", container: "ogg", codec: "vorbis",
                  tracks: ["Last Call", "Rain on Ninth", "Slow Train"]),
        AlbumSpec(artist: "Blue Hour Trio", title: "Live at the Cellar", year: 2010, genre: "Jazz", container: "mp3", codec: "mp3",
                  tracks: ["Set One", "Set Two", "Encore"]),
        AlbumSpec(artist: "Various Artists", title: "Jellyamp Sampler", year: 2024, genre: "Electronic", container: "mp3", codec: "mp3",
                  tracks: ["Sampler Intro", "Sampler Outro"]),
    ]

    static let trackSeconds = 30.0
    static let trackCount = albums.reduce(0) { $0 + $1.tracks.count }
    static let albumArtists = Set(albums.map(\.artist))
    static let genres = Set(albums.map(\.genre))
    /// The compilation credits its tracks to these two instead of the album artist.
    static let samplerTrackArtists = ["Sampler Intro": "Aurora Drift", "Sampler Outro": "Neon Circuit"]

    static func spec(_ title: String) -> AlbumSpec {
        albums.first { $0.title == title }!
    }

    /// An ID no item has (well-formed, so the server answers 404 rather than 400).
    static let unknownID = "00000000000000000000000000000001"
}

// MARK: - Server access

struct LiveConfig {
    var url: URL
    var user: String
    var password: String

    static let current: LiveConfig? = {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["JELLYFIN_TEST_URL"], !raw.isEmpty, let url = URL(string: raw),
              let user = env["JELLYFIN_TEST_USER"], !user.isEmpty,
              let password = env["JELLYFIN_TEST_PASSWORD"]
        else { return nil }
        return LiveConfig(url: url, user: user, password: password)
    }()
}

/// What every test needs, fetched once per run: the signed-in session and an
/// index of the library as the API returns it.
struct LiveContext: Sendable {
    var session: JellyfinSession
    var albums: [String: Album]
    var tracksByAlbum: [String: [Track]]
    var artists: [String: Artist]

    var library: MusicLibraryAPI { MusicLibraryAPI(session: session) }
    var allTracks: [Track] { Library.albums.flatMap { tracksByAlbum[$0.title] ?? [] } }

    func album(_ title: String) -> Album { albums[title]! }
    func artist(_ name: String) -> Artist { artists[name]! }
    func track(_ title: String) -> Track { allTracks.first { $0.title == title }! }
}

actor LiveServer {
    static let shared = LiveServer()
    private var loading: Task<LiveContext, Error>?

    func context() async throws -> LiveContext {
        guard let config = LiveConfig.current else {
            throw XCTSkip("set JELLYFIN_TEST_URL, JELLYFIN_TEST_USER and JELLYFIN_TEST_PASSWORD to run the live Jellyfin tests")
        }
        if let loading {
            return try await loading.value
        }
        let task = Task { try await Self.load(config) }
        loading = task
        return try await task.value
    }

    private static func load(_ config: LiveConfig) async throws -> LiveContext {
        // A device ID of our own: signing in again with a device ID that is
        // already signed in revokes the older token, which would log out
        // whoever else is testing against the same server.
        let anonymous = JellyfinSession(
            serverURL: config.url,
            deviceID: "jellyamp-live-tests-\(UUID().uuidString)",
            deviceName: "Live tests",
            clientName: "Jellyamp Tests"
        )
        let session = try await JellyfinAuthenticator().authenticateByName(
            session: anonymous, username: config.user, password: config.password)
        LogoutAtExit.register(session)

        let api = MusicLibraryAPI(session: session)
        let albums = try await api.albums(sortBy: "SortName", sortOrder: "Ascending", startIndex: 0, limit: 500)
        var tracksByAlbum: [String: [Track]] = [:]
        for album in albums {
            tracksByAlbum[album.title] = try await api.tracks(inAlbum: album.id)
        }
        let artists = try await api.artists(sortBy: "SortName", startIndex: 0, limit: 500)
        return LiveContext(
            session: session,
            albums: Dictionary(albums.map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first }),
            tracksByAlbum: tracksByAlbum,
            artists: Dictionary(artists.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        )
    }
}

/// Signs the test session out when the test run ends so runs do not pile up
/// devices on a long-lived server.
final class LogoutAtExit: NSObject, XCTestObservation, @unchecked Sendable {
    private static let lock = NSLock()
    private static var registered: LogoutAtExit?
    private let session: JellyfinSession

    private init(session: JellyfinSession) {
        self.session = session
    }

    static func register(_ session: JellyfinSession) {
        lock.lock(); defer { lock.unlock() }
        guard registered == nil else { return }
        let observer = LogoutAtExit(session: session)
        registered = observer
        XCTestObservationCenter.shared.addTestObserver(observer)
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        let done = DispatchSemaphore(value: 0)
        let request = session.request(path: "Sessions/Logout", method: "POST")
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 5)
    }
}

/// Base class: skips without configuration, signs in once per run.
class LiveTestCase: XCTestCase {
    private var loaded: LiveContext?

    var context: LiveContext { loaded! }
    var session: JellyfinSession { context.session }
    var library: MusicLibraryAPI { context.library }

    override func setUp() async throws {
        try await super.setUp()
        loaded = try await LiveServer.shared.context()
    }

    // MARK: Raw HTTP (for what the API returns as URLs, and for test fixtures)

    struct Response {
        var status: Int
        var headers: [String: String]
        var body: Data

        var contentType: String { headers["content-type"] ?? "" }
    }

    /// Plain GET the way AVPlayer / an image view would do it: no
    /// `Authorization` header, only what is in the URL.
    func fetch(_ url: URL, headers: [String: String] = [:]) async throws -> Response {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return try await perform(request)
    }

    /// Authenticated call outside the API under test (fixtures, clean-up).
    @discardableResult
    func raw(_ method: String, _ path: String, query: [URLQueryItem] = []) async throws -> Response {
        var request = session.request(path: path, query: query, method: method)
        request.timeoutInterval = 60
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            headers[String(describing: name).lowercased()] = String(describing: value)
        }
        return Response(status: http.statusCode, headers: headers, body: data)
    }

    /// `UserData` of an item as the server has it right now.
    func userData(of itemID: String) async throws -> (isFavorite: Bool, played: Bool, playCount: Int) {
        let response = try await raw("GET", "Items/\(itemID)", query: [URLQueryItem(name: "userId", value: session.userID)])
        XCTAssertEqual(response.status, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let data = object["UserData"] as? [String: Any] ?? [:]
        return (data["IsFavorite"] as? Bool ?? false, data["Played"] as? Bool ?? false, data["PlayCount"] as? Int ?? 0)
    }
}

/// Runs `body`, then `cleanup` — also when `body` throws.
func withCleanup<T>(_ body: () async throws -> T, cleanup: () async -> Void) async throws -> T {
    do {
        let result = try await body()
        await cleanup()
        return result
    } catch {
        await cleanup()
        throw error
    }
}

func assertThrowsJellyfinError(
    _ expected: JellyfinError,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
) async {
    do {
        try await body()
        XCTFail("expected \(expected) \(message)", file: file, line: line)
    } catch let error as JellyfinError {
        XCTAssertEqual(error, expected, message, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error) \(message)", file: file, line: line)
    }
}

extension Sequence where Element == Track {
    var titles: [String] { map(\.title) }
}

extension Sequence where Element == Album {
    var titles: [String] { map(\.title) }
}
