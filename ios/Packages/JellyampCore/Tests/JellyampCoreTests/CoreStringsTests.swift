import XCTest
@testable import JellyampCore

/// The app shell replaces `CoreStrings.current` with localized values; these
/// tests pin down that every Core helper really reads it (and that the
/// English defaults are what the other suites assert on).
final class CoreStringsTests: XCTestCase {
    override func tearDown() {
        CoreStrings.current = CoreStrings()
        super.tearDown()
    }

    private func installGerman() {
        var strings = CoreStrings()
        strings.songCount = { "\($0) Titel" }
        strings.trackNumber = { "Titel \($0)" }
        strings.spokenHours = { $0 == 1 ? "1 Stunde" : "\($0) Stunden" }
        strings.spokenMinutes = { $0 == 1 ? "1 Minute" : "\($0) Minuten" }
        strings.spokenSeconds = { $0 == 1 ? "1 Sekunde" : "\($0) Sekunden" }
        strings.approximateSeconds = { "\($0) Sek." }
        strings.approximateMinutes = { "\($0) Min." }
        strings.approximateHours = { "\($0) Std." }
        strings.approximateHoursAndMinutes = { "\($0) Std. \($1) Min." }
        strings.libraryRadio = "Bibliotheksradio"
        strings.decadeTitle = { "\($0)er" }
        strings.decadeShortTitle = { "\($0)er" }
        strings.scrobbleServiceUnreachable = "Der Dienst ist nicht erreichbar."
        CoreStrings.current = strings
    }

    func testEnglishDefaults() {
        XCTAssertEqual(DurationText.approximate(4320), "1 hr 12 min")
        XCTAssertEqual(DurationText.spoken(3661), "1 hour, 1 minute, 1 second")
        XCTAssertEqual(DurationText.spoken(0), "0 seconds")
        XCTAssertEqual(Decade(containing: 1987).title, "1980s")
        XCTAssertEqual(Decade(containing: 2004).shortTitle, "00s")
        XCTAssertEqual(StationDefinition.libraryRadio.title, "Library Radio")
        XCTAssertEqual(ScrobbleDeliveryError.offline.message, "The service could not be reached.")
    }

    func testDurationsUseInstalledStrings() {
        installGerman()
        XCTAssertEqual(DurationText.approximate(45), "45 Sek.")
        XCTAssertEqual(DurationText.approximate(600), "10 Min.")
        XCTAssertEqual(DurationText.approximate(3600), "1 Std.")
        XCTAssertEqual(DurationText.approximate(4320), "1 Std. 12 Min.")
        XCTAssertEqual(DurationText.spoken(3725), "1 Stunde, 2 Minuten, 5 Sekunden")
    }

    func testMetadataAndAccessibilityUseInstalledStrings() {
        installGerman()
        XCTAssertEqual(
            AlbumPresentation.metadataLine(year: 2021, genres: ["Electronic"], trackCount: 3, duration: 900),
            "2021 · Electronic · 3 Titel · 15 Min."
        )
        let playlist = Playlist(id: "p", name: "Morgens", trackCount: 12)
        XCTAssertEqual(AccessibilityText.playlist(playlist), "Morgens, 12 Titel")
        let track = Track(id: "t", title: "Phosphor", artistName: "Afterimage", duration: 300)
        XCTAssertEqual(
            AccessibilityText.trackRow(track, trackNumber: 1),
            "Titel 1, Phosphor, Afterimage, 5 Minuten"
        )
    }

    func testStationTitlesUseInstalledStringsButSeedsStayStable() {
        installGerman()
        let decade = Decade(containing: 1987)
        XCTAssertEqual(decade.title, "1980er")
        XCTAssertEqual(decade.shortTitle, "80er")
        // The seed goes to the Sonic API and must never be translated.
        XCTAssertEqual(decade.seed, "1980s")
        XCTAssertEqual(StationDefinition.decade(decade).title, "1980er")
        XCTAssertEqual(StationDefinition.decade(decade).id, "station.decade.1980")
        XCTAssertEqual(StationDefinition.libraryRadio.title, "Bibliotheksradio")
        XCTAssertEqual(StationDefinition.libraryRadio.id, "station.library")
    }

    func testScrobbleMessagesUseInstalledStrings() {
        installGerman()
        XCTAssertEqual(ScrobbleDeliveryError.offline.message, "Der Dienst ist nicht erreichbar.")
    }
}
