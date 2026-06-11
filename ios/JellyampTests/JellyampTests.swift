import XCTest
@testable import Jellyamp

/// Apple-framework-bound tests (GRDB stores, EnginePlayer graph) run here on
/// the macOS CI job. Platform-independent logic is tested in the SPM packages.
final class JellyampTests: XCTestCase {
    func testPlaceholder() {
        XCTAssertTrue(true)
    }
}
