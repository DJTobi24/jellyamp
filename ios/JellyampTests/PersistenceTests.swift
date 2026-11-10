import XCTest
import Security
import JellyampCore
import JellyfinBackend
@testable import Jellyamp

// App-shell logic that needs Apple frameworks (Keychain, UserDefaults, the
// app's sandbox) and therefore cannot be covered by the Linux package tests.
// These run in the app's process on a simulator; every test puts back what it
// found, so running them on a signed-in development device is harmless.

final class KeychainCredentialStoreTests: XCTestCase {
    /// Must match `KeychainCredentialStore.service`.
    private let service = "dev.djtobi.jellyamp"
    private let store = KeychainCredentialStore()
    private var savedItems: [String: Data] = [:]
    private let accounts = ["session", "sonicApiKey", "listenBrainzToken", "lastFMSessionKey"]

    override func setUpWithError() throws {
        savedItems = [:]
        for account in accounts {
            if let data = readRaw(account) { savedItems[account] = data }
        }
        // An unsigned test host has no Keychain; nothing here can pass then.
        writeRaw(Data("probe".utf8), account: "session")
        guard readRaw("session") == Data("probe".utf8) else {
            throw XCTSkip("The Keychain is not available to this test host (unsigned build?).")
        }
        store.clear()
        store.clearScrobblingCredentials()
    }

    override func tearDown() {
        for account in accounts {
            deleteRaw(account)
            if let data = savedItems[account] { writeRaw(data, account: account) }
        }
    }

    func testSessionRoundTrip() throws {
        XCTAssertNil(store.loadSession())
        XCTAssertNil(store.loadAccount())

        let session = JellyfinSession(
            serverURL: try XCTUnwrap(URL(string: "https://music.example.org:8920/jellyfin")),
            deviceID: "device-1",
            accessToken: "token-1",
            userID: "user-1"
        )
        let account = JellyfinAccount(serverName: "Home", serverVersion: "10.10.7", userName: "Mira")
        store.save(session: session, account: account)

        let loaded = try XCTUnwrap(store.loadSession())
        XCTAssertEqual(loaded.serverURL, session.serverURL)
        XCTAssertEqual(loaded.deviceID, "device-1")
        XCTAssertEqual(loaded.accessToken, "token-1")
        XCTAssertEqual(loaded.userID, "user-1")
        XCTAssertTrue(loaded.isAuthenticated)
        XCTAssertEqual(store.loadAccount(), account)

        // Saving again replaces, it does not add a second item.
        var renewed = session
        renewed.accessToken = "token-2"
        store.save(session: renewed)
        XCTAssertEqual(store.loadSession()?.accessToken, "token-2")
        XCTAssertNil(store.loadAccount()?.serverName)
    }

    /// The blob written by the first release had no account fields. People
    /// updating from it must stay signed in.
    func testSessionStoredByAnOlderVersionStillLoads() throws {
        let legacy = #"{"serverURL":"http:\/\/nas.lan:8096","deviceID":"old-device","accessToken":"old-token","userID":"old-user"}"#
        writeRaw(Data(legacy.utf8), account: "session")

        let loaded = try XCTUnwrap(store.loadSession())
        XCTAssertEqual(loaded.serverURL.absoluteString, "http://nas.lan:8096")
        XCTAssertEqual(loaded.deviceID, "old-device")
        XCTAssertEqual(loaded.accessToken, "old-token")
        XCTAssertEqual(loaded.userID, "old-user")
        XCTAssertTrue(loaded.isAuthenticated)
        let account = try XCTUnwrap(store.loadAccount())
        XCTAssertNil(account.serverName)
        XCTAssertNil(account.serverVersion)
        XCTAssertNil(account.userName)
    }

    func testFieldsAddedByNewerVersionsAreIgnored() throws {
        let future = #"{"serverURL":"https:\/\/a.example","deviceID":"d","accessToken":"t","userID":"u","userName":"Ann","somethingNew":{"x":1}}"#
        writeRaw(Data(future.utf8), account: "session")
        XCTAssertEqual(store.loadSession()?.userID, "u")
        XCTAssertEqual(store.loadAccount()?.userName, "Ann")
    }

    func testGarbageIsNotASession() {
        writeRaw(Data("not json".utf8), account: "session")
        XCTAssertNil(store.loadSession())
        XCTAssertNil(store.loadAccount())
    }

    func testSonicKeyAndClear() throws {
        XCTAssertNil(store.loadSonicAPIKey())
        store.saveSonicAPIKey("käy-✓")
        XCTAssertEqual(store.loadSonicAPIKey(), "käy-✓")
        store.clearSonicAPIKey()
        XCTAssertNil(store.loadSonicAPIKey())

        store.saveSonicAPIKey("again")
        store.save(session: JellyfinSession(serverURL: try XCTUnwrap(URL(string: "http://x")), deviceID: "d", accessToken: "t", userID: "u"))
        store.saveListenBrainzToken("lb")
        store.saveLastFMSessionKey("fm")
        store.clear()
        XCTAssertNil(store.loadSession())
        XCTAssertNil(store.loadSonicAPIKey())
        // Scrobbling accounts are not part of the Jellyfin sign-in.
        XCTAssertEqual(store.loadListenBrainzToken(), "lb")
        XCTAssertEqual(store.loadLastFMSessionKey(), "fm")
        store.clearScrobblingCredentials()
        XCTAssertNil(store.loadListenBrainzToken())
        XCTAssertNil(store.loadLastFMSessionKey())
    }

    // MARK: Raw Keychain access (to plant and preserve items)

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func readRaw(_ account: String) -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func writeRaw(_ data: Data, account: String) {
        deleteRaw(account)
        var request = query(account)
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(request as CFDictionary, nil)
    }

    private func deleteRaw(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

final class UserDefaultsSettingsStoreTests: XCTestCase {
    /// Must match `UserDefaultsSettingsStore.key`.
    private let key = "jellyamp.settings"
    private var saved: Data?

    override func setUp() {
        saved = UserDefaults.standard.data(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        if let saved {
            UserDefaults.standard.set(saved, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func testDefaultsWhenNothingIsStored() {
        XCTAssertEqual(UserDefaultsSettingsStore().loadSettings(), AppSettings())
    }

    func testRoundTrip() throws {
        var settings = AppSettings()
        settings.crossfadeDuration = 7
        settings.autoplayEnabled = false
        settings.offlineModeEnabled = true
        settings.downloadsOverCellular = true
        settings.activeEQPresetID = "rock"
        settings.visualizerStyle = .wave
        settings.sonicServerURL = try XCTUnwrap(URL(string: "https://sonic.example.org"))
        UserDefaultsSettingsStore().save(settings)

        // A second instance, as after a relaunch.
        XCTAssertEqual(UserDefaultsSettingsStore().loadSettings(), settings)
    }

    func testUnreadableDataFallsBackToDefaults() {
        UserDefaults.standard.set(Data("{broken".utf8), forKey: key)
        XCTAssertEqual(UserDefaultsSettingsStore().loadSettings(), AppSettings())
    }

    func testSettingsFromAnOlderVersionKeepTheirValues() {
        // Only the two fields the very first version stored.
        UserDefaults.standard.set(Data(#"{"crossfadeDuration":4,"loudnessLevelingEnabled":false}"#.utf8), forKey: key)
        let loaded = UserDefaultsSettingsStore().loadSettings()
        XCTAssertEqual(loaded.crossfadeDuration, 4)
        XCTAssertFalse(loaded.loudnessLevelingEnabled)
        // Everything added since has its default.
        XCTAssertEqual(loaded.autoplayEnabled, AppSettings().autoplayEnabled)
        XCTAssertEqual(loaded.visualizerStyle, AppSettings().visualizerStyle)
    }
}

final class LibraryCacheTests: XCTestCase {
    private let scopeA = "tests-\(UUID().uuidString)"
    private let scopeB = "tests-\(UUID().uuidString)"

    override func tearDown() {
        for scope in [scopeA, scopeB] {
            let cache = LibraryCache(scope: scope)
            for key in ["albums", "big", "small", "odd/key:1"] { cache.remove(for: key) }
        }
    }

    private func album(_ number: Int) -> Album {
        Album(id: "album-\(number)", title: "Album \(number)", artistName: "Artist", productionYear: 2000 + number, genres: ["Jazz"], trackCount: 9)
    }

    func testRoundTripAndRemove() {
        let cache = LibraryCache(scope: scopeA)
        XCTAssertNil(cache.load([Album].self, for: "albums"))
        let albums = (1...20).map(album)
        cache.save(albums, for: "albums")
        XCTAssertEqual(cache.load([Album].self, for: "albums"), albums)
        // A fresh instance reads the same file.
        XCTAssertEqual(LibraryCache(scope: scopeA).load([Album].self, for: "albums"), albums)
        // The wrong type is "nothing cached", not a crash.
        XCTAssertNil(cache.load([Int].self, for: "albums"))
        cache.remove(for: "albums")
        XCTAssertNil(cache.load([Album].self, for: "albums"))
    }

    func testAccountsDoNotSeeEachOthersEntries() {
        LibraryCache(scope: scopeA).save([album(1)], for: "albums")
        XCTAssertNil(LibraryCache(scope: scopeB).load([Album].self, for: "albums"))
        XCTAssertNotNil(LibraryCache(scope: scopeA).load([Album].self, for: "albums"))
    }

    func testKeysWithPathCharactersStayInsideTheCacheDirectory() {
        let cache = LibraryCache(scope: scopeA)
        cache.save([1, 2, 3], for: "odd/key:1")
        XCTAssertEqual(cache.load([Int].self, for: "odd/key:1"), [1, 2, 3])
    }

    /// A single entry is capped (2 MB): callers cache first pages, never a
    /// whole library, and an oversized save must not leave a stale file.
    func testOversizedEntriesAreNotStored() {
        let cache = LibraryCache(scope: scopeA)
        cache.save(["small"], for: "big")
        XCTAssertEqual(cache.load([String].self, for: "big"), ["small"])

        let chunk = String(repeating: "x", count: 1024)
        let oversized = Array(repeating: chunk, count: 2200)   // ≈ 2.2 MB of JSON
        cache.save(oversized, for: "big")
        XCTAssertNil(cache.load([String].self, for: "big"), "the previous value must go when the new one is too large")

        let allowed = Array(repeating: chunk, count: 1500)     // ≈ 1.5 MB
        cache.save(allowed, for: "small")
        XCTAssertEqual(cache.load([String].self, for: "small")?.count, 1500)
    }
}

final class DownloadStoreTests: XCTestCase {
    private var createdFiles: [URL] = []

    override func setUp() {
        DownloadStore.ensureDirectory()
    }

    override func tearDown() {
        for url in createdFiles { try? FileManager.default.removeItem(at: url) }
        createdFiles = []
        DownloadStore.setCompleteFileNames([:])
    }

    private func track(id: String = "tests-\(UUID().uuidString)", container: String?, codec: String? = nil) -> Track {
        Track(id: id, title: "T", artistName: "A", duration: 10, container: container, codec: codec)
    }

    private func touch(_ url: URL, bytes: Int = 16) throws {
        try Data(repeating: 7, count: bytes).write(to: url)
        createdFiles.append(url)
    }

    func testDirectoryLayout() {
        let directory = DownloadStore.directory
        XCTAssertEqual(directory.lastPathComponent, "Downloads")
        XCTAssertTrue(directory.path.contains("Application Support"))
        XCTAssertEqual(DownloadStore.indexURL.deletingLastPathComponent().path, directory.path)
        XCTAssertEqual(DownloadStore.resumeDirectory.deletingLastPathComponent().path, directory.path)
        XCTAssertEqual(DownloadStore.artworkDirectory.deletingLastPathComponent().path, directory.path)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: DownloadStore.resumeDirectory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// The extension is how the player recognises the format of a download.
    func testFileNamesFollowTheContainer() {
        XCTAssertEqual(DownloadStore.fileName(for: track(id: "abc", container: "flac")), "abc.flac")
        XCTAssertEqual(DownloadStore.fileName(for: track(id: "abc", container: "aac")), "abc.aac")
        // ffprobe's format list for MP4-family files.
        XCTAssertEqual(DownloadStore.fileName(for: track(id: "abc", container: "mov,mp4,m4a,3gp,3g2,mj2")), "abc.m4a")
        // No container: the codec decides.
        XCTAssertEqual(DownloadStore.fileName(for: track(id: "abc", container: nil, codec: "alac")), "abc.m4a")
        XCTAssertEqual(DownloadStore.fileName(for: track(id: "abc", container: nil, codec: nil)), "abc.mp3")
        XCTAssertEqual(DownloadStore.fileName(for: track(id: "abc", container: "FLAC")), "abc.flac")
    }

    func testServerSuppliedValuesCannotEscapeTheDirectory() {
        let hostile = track(id: "../../etc/passwd", container: "../../x")
        let url = DownloadStore.fileURL(for: hostile)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, DownloadStore.directory.standardizedFileURL.path)
        XCTAssertFalse(url.lastPathComponent.contains("/"))
        XCTAssertFalse(DownloadStore.fileName(for: hostile).contains(".."))
    }

    func testLocalURLOnlyForFilesThatExist() throws {
        let flac = track(container: "flac")
        XCTAssertNil(DownloadStore.localURL(for: flac))
        try touch(DownloadStore.fileURL(for: flac))
        XCTAssertEqual(DownloadStore.localURL(for: flac)?.lastPathComponent, "\(flac.id).flac")
    }

    /// A list response without media sources yields a `Track` with no
    /// container; the file registered at download time must still be found.
    func testRegisteredNameWinsOverTheDerivedOne() throws {
        let asDownloaded = track(container: "flac")
        try touch(DownloadStore.fileURL(for: asDownloaded))
        let asListedLater = track(id: asDownloaded.id, container: nil)
        XCTAssertNil(DownloadStore.localURL(for: asListedLater), "without the registry the derived name is .mp3")
        DownloadStore.setCompleteFileNames([asDownloaded.id: DownloadStore.fileName(for: asDownloaded)])
        XCTAssertEqual(DownloadStore.localURL(for: asListedLater)?.pathExtension, "flac")
    }

    func testAudioFileListingSkipsBookkeeping() throws {
        let file = track(container: "mp3")
        try touch(DownloadStore.fileURL(for: file), bytes: 1234)
        let listed = DownloadStore.audioFiles()
        XCTAssertEqual(listed[DownloadStore.fileName(for: file)], 1234)
        for reserved in ["index.json", "genres.json", "Resume", "Artwork"] {
            XCTAssertNil(listed[reserved])
        }
        DownloadStore.deleteFile(named: DownloadStore.fileName(for: file))
        XCTAssertNil(DownloadStore.audioFiles()[DownloadStore.fileName(for: file)])
    }

    func testResumeDataIsHandedOutOnce() {
        let id = "tests-\(UUID().uuidString)"
        XCTAssertNil(DownloadStore.takeResumeData(for: id))
        DownloadStore.saveResumeData(Data([1, 2, 3]), for: id)
        XCTAssertEqual(DownloadStore.takeResumeData(for: id), Data([1, 2, 3]))
        XCTAssertNil(DownloadStore.takeResumeData(for: id))

        DownloadStore.saveResumeData(Data([4]), for: id)
        DownloadStore.deleteResumeData(for: id)
        XCTAssertNil(DownloadStore.takeResumeData(for: id))
    }
}
