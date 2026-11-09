import XCTest
@testable import JellyampCore

/// A clock the tests can move.
private final class TestClock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_700_000_000)
}

final class BoundedJSONCacheTests: XCTestCase {
    private var directory: URL!
    private let clock = TestClock()

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("jellyamp-cache-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeCache(scope: String = "user", maxAge: TimeInterval = 100, maxEntryBytes: Int = 10_000, maxTotalBytes: Int = 100_000) -> BoundedJSONCache {
        let clock = self.clock
        return BoundedJSONCache(
            directory: directory, scope: scope, maxAge: maxAge, maxEntryBytes: maxEntryBytes, maxTotalBytes: maxTotalBytes,
            now: { clock.date }
        )
    }

    func testRoundTrip() {
        let cache = makeCache()
        let albums = [Album(id: "a", title: "Afterimage", artistName: "Neon Circuit", productionYear: 2021)]
        XCTAssertTrue(cache.save(albums, for: "library.albums"))
        XCTAssertEqual(cache.load([Album].self, for: "library.albums"), albums)
        XCTAssertNil(cache.load([Album].self, for: "missing"))
    }

    func testScopesAreIsolated() {
        makeCache(scope: "alice").save(["a"], for: "k")
        XCTAssertNil(makeCache(scope: "bob").load([String].self, for: "k"))
        XCTAssertEqual(makeCache(scope: "alice").load([String].self, for: "k"), ["a"])
    }

    func testExpiredEntryIsAMissAndDeleted() {
        let cache = makeCache(maxAge: 100)
        cache.save(["a"], for: "k")
        clock.date += 99
        XCTAssertNotNil(cache.load([String].self, for: "k"))
        clock.date += 2
        XCTAssertNil(cache.load([String].self, for: "k"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.fileURL(for: "k").path))
    }

    func testEntryFromTheFutureIsNotTrustedForever() {
        // Clock moved backwards (time zone / manual change): still bounded.
        let cache = makeCache(maxAge: 100)
        cache.save(["a"], for: "k")
        clock.date -= 500
        XCTAssertNil(cache.load([String].self, for: "k"))
    }

    func testCorruptFileIsAMissAndDeleted() throws {
        let cache = makeCache()
        cache.save(["a"], for: "k")
        let url = cache.fileURL(for: "k")
        try Data("{\"version\":1,\"savedAt\":12,\"payl".utf8).write(to: url) // truncated write
        XCTAssertNil(cache.load([String].self, for: "k"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        // The key is usable again afterwards.
        cache.save(["b"], for: "k")
        XCTAssertEqual(cache.load([String].self, for: "k"), ["b"])
    }

    func testLegacyBarePayloadAndTypeMismatchAreMisses() throws {
        let cache = makeCache()
        // Files written before the envelope existed were the bare payload.
        try Data("[\"old\"]".utf8).write(to: cache.fileURL(for: "legacy"))
        XCTAssertNil(cache.load([String].self, for: "legacy"))
        // The model behind a key changed between app versions.
        cache.save(["text"], for: "typed")
        XCTAssertNil(cache.load([Album].self, for: "typed"))
    }

    func testOversizedEntryIsNotWrittenAndDropsThePreviousValue() {
        let cache = makeCache(maxEntryBytes: 200)
        XCTAssertTrue(cache.save(["small"], for: "k"))
        let big = Array(repeating: "0123456789", count: 100)
        XCTAssertFalse(cache.save(big, for: "k"))
        XCTAssertNil(cache.load([String].self, for: "k"), "a stale first page must not outlive the refusal")
    }

    func testPruneRemovesOldestFilesFirst() throws {
        let cache = makeCache(maxEntryBytes: 10_000, maxTotalBytes: 2_500)
        let payload = Array(repeating: "0123456789", count: 70) // ~1 kB each
        for (index, key) in ["oldest", "middle", "newest"].enumerated() {
            cache.save(payload, for: key)
            // File modification dates drive the eviction order.
            let date = Date(timeIntervalSince1970: 1_000_000 + Double(index) * 100)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: cache.fileURL(for: key).path)
        }
        cache.prune()
        XCTAssertNil(cache.load([String].self, for: "oldest"))
        XCTAssertNotNil(cache.load([String].self, for: "middle"))
        XCTAssertNotNil(cache.load([String].self, for: "newest"))
    }

    func testPruneKeepsEverythingWithinBudget() {
        let cache = makeCache()
        cache.save(["a"], for: "one")
        cache.save(["b"], for: "two")
        cache.prune()
        XCTAssertNotNil(cache.load([String].self, for: "one"))
        XCTAssertNotNil(cache.load([String].self, for: "two"))
    }

    func testKeysWithPathSeparatorsStayInsideTheDirectory() {
        let cache = makeCache()
        cache.save(["a"], for: "genre/../../escape")
        XCTAssertEqual(cache.fileURL(for: "genre/../../escape").deletingLastPathComponent().path, directory.path)
        XCTAssertEqual(cache.load([String].self, for: "genre/../../escape"), ["a"])
    }
}
