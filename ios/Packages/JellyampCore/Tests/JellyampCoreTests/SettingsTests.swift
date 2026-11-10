import XCTest
@testable import JellyampCore

final class SettingsTests: XCTestCase {
    func testDecodingOldPayloadKeepsSavedValuesAndDefaultsNewOnes() throws {
        // A payload written before autoplay/offline/scrobbling settings existed.
        let old = #"{"crossfadeDuration":6,"loudnessLevelingEnabled":false,"loudnessPreampDB":0,"silenceCompressionEnabled":false,"playbackProfile":{"maxBitrateCellular":320000,"forceTranscodeOnCellular":false},"sleepTimerFadeOut":10}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertEqual(settings.crossfadeDuration, 6)
        XCTAssertFalse(settings.loudnessLevelingEnabled)
        XCTAssertTrue(settings.autoplayEnabled)
        XCTAssertFalse(settings.offlineModeEnabled)
        XCTAssertEqual(settings.smartSync, SmartSyncRules())
        XCTAssertEqual(settings.scrobbling, ScrobblingSettings())
        XCTAssertEqual(settings.visualizerStyle, .bars)
    }

    func testRoundTrip() throws {
        var settings = AppSettings(crossfadeDuration: 4)
        settings.offlineModeEnabled = true
        settings.scrobbling.lastFMEnabled = true
        settings.visualizerStyle = .wave
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), settings)
    }

    func testScrobblingSettingsSavedBeforeAccountFieldsExistedStillDecode() throws {
        let old = #"{"scrobbling":{"listenBrainzEnabled":true,"lastFMEnabled":false,"lastFMUsername":"rj"}}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(old.utf8))
        XCTAssertTrue(settings.scrobbling.listenBrainzEnabled)
        XCTAssertEqual(settings.scrobbling.lastFMUsername, "rj")
        XCTAssertNil(settings.scrobbling.listenBrainzUsername)
        XCTAssertNil(settings.scrobbling.listenBrainzServerURL)

        var updated = settings
        updated.scrobbling.listenBrainzUsername = "rob"
        updated.scrobbling.listenBrainzServerURL = URL(string: "https://listens.example.org")
        let data = try JSONEncoder().encode(updated)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), updated)
    }

    func testEmptyObjectDecodesToDefaults() throws {
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)), AppSettings())
    }
}
