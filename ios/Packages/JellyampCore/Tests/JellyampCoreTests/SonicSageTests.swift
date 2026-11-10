import XCTest
@testable import JellyampCore

private func track(_ id: String, duration: TimeInterval = 100) -> Track {
    Track(id: id, title: "Title \(id)", artistName: "Artist", albumName: nil, albumID: nil, duration: duration)
}

final class SagePromptTests: XCTestCase {
    func testNormalizeTrimsAndCollapsesWhitespace() {
        XCTAssertEqual(SagePrompt.normalize("  rainy   sunday\n\nmorning\tjazz \n"), "rainy sunday morning jazz")
        XCTAssertEqual(SagePrompt.normalize(" \n\t "), "")
        XCTAssertEqual(SagePrompt.normalize("jazz"), "jazz")
    }

    func testValidateRejectsBlankPrompts() {
        XCTAssertEqual(SagePrompt.validate(""), .failure(.empty))
        XCTAssertEqual(SagePrompt.validate("  \n "), .failure(.empty))
    }

    func testValidateReturnsNormalizedPrompt() {
        XCTAssertEqual(SagePrompt.validate("  90s rock\nfor a road trip "), .success("90s rock for a road trip"))
    }

    func testValidateEnforcesServerLimit() {
        let atLimit = String(repeating: "a", count: SagePrompt.maxLength)
        XCTAssertEqual(SagePrompt.validate(atLimit), .success(atLimit))
        XCTAssertEqual(SagePrompt.validate(atLimit + "bcd"), .failure(.tooLong(excess: 3)))
        // Whitespace that normalization removes does not count.
        XCTAssertEqual(SagePrompt.validate("  " + atLimit + "\n\n"), .success(atLimit))
    }

    func testLengthCountsCodePointsLikeTheServer() {
        // One Character, five code points (family emoji with joiners).
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        XCTAssertEqual(family.count, 1)
        XCTAssertEqual(SagePrompt.length(of: family), 5)
        let prompt = String(repeating: "a", count: SagePrompt.maxLength - 4) + family
        XCTAssertEqual(SagePrompt.validate(prompt), .failure(.tooLong(excess: 1)))
    }

    func testRemainingCharacters() {
        XCTAssertEqual(SagePrompt.remainingCharacters(for: ""), 1000)
        XCTAssertEqual(SagePrompt.remainingCharacters(for: "  calm  focus "), 1000 - 10)
        XCTAssertEqual(SagePrompt.remainingCharacters(for: String(repeating: "x", count: 1002)), -2)
    }
}

final class SageTrackCountTests: XCTestCase {
    func testChoicesAndDefaultAreWithinServerRange() {
        XCTAssertEqual(SageTrackCount.choices, [15, 30, 50])
        XCTAssertTrue(SageTrackCount.choices.contains(SageTrackCount.defaultCount))
        for choice in SageTrackCount.choices {
            XCTAssertTrue(SageTrackCount.allowed.contains(choice))
        }
    }

    func testClamp() {
        XCTAssertEqual(SageTrackCount.clamp(0), 1)
        XCTAssertEqual(SageTrackCount.clamp(-5), 1)
        XCTAssertEqual(SageTrackCount.clamp(30), 30)
        XCTAssertEqual(SageTrackCount.clamp(500), 200)
    }
}

final class SageRecentPromptsTests: XCTestCase {
    func testRecordPutsNewestFirst() {
        var recents = SageRecentPrompts()
        recents.record("jazz")
        recents.record("rock")
        recents.record("ambient")
        XCTAssertEqual(recents.prompts, ["ambient", "rock", "jazz"])
    }

    func testRecordDedupesCaseInsensitivelyAndKeepsNewestSpelling() {
        var recents = SageRecentPrompts()
        recents.record("Rainy Sunday Jazz")
        recents.record("rock")
        recents.record("rainy  sunday\nJAZZ")
        XCTAssertEqual(recents.prompts, ["rainy sunday JAZZ", "rock"])
    }

    func testRecordIgnoresBlankPrompts() {
        var recents = SageRecentPrompts(prompts: ["jazz"])
        recents.record("   \n")
        XCTAssertEqual(recents.prompts, ["jazz"])
    }

    func testCapDropsOldest() {
        var recents = SageRecentPrompts()
        for index in 1...12 {
            recents.record("prompt \(index)")
        }
        XCTAssertEqual(recents.prompts.count, 10)
        XCTAssertEqual(recents.prompts.first, "prompt 12")
        XCTAssertEqual(recents.prompts.last, "prompt 3")
    }

    func testReRecordingAtCapDoesNotDropAnything() {
        var recents = SageRecentPrompts()
        for index in 1...10 {
            recents.record("prompt \(index)")
        }
        recents.record("PROMPT 1")
        XCTAssertEqual(recents.prompts.count, 10)
        XCTAssertEqual(recents.prompts.first, "PROMPT 1")
        XCTAssertEqual(recents.prompts.last, "prompt 2")
    }

    func testInitSanitizesStoredValues() {
        let stored = ["  Jazz ", "", "jazz", "rock", "ROCK", "ambient"]
        let recents = SageRecentPrompts(prompts: stored, limit: 2)
        XCTAssertEqual(recents.prompts, ["Jazz", "rock"])
        XCTAssertEqual(SageRecentPrompts(prompts: ["a"], limit: -1).prompts, [])
    }

    func testRemoveAndRemoveAll() {
        var recents = SageRecentPrompts(prompts: ["jazz", "rock", "ambient"])
        recents.remove(" ROCK ")
        XCTAssertEqual(recents.prompts, ["jazz", "ambient"])
        recents.remove("unknown")
        XCTAssertEqual(recents.prompts, ["jazz", "ambient"])
        recents.removeAll()
        XCTAssertTrue(recents.isEmpty)
    }
}

final class SageResultTests: XCTestCase {
    private func result(ids: [String], resolved: [String], requested: Int, title: String = "Title") -> SageResult {
        SageResult(title: title, description: " desc ", itemIDs: ids, resolved: resolved.map { track($0) }, requestedCount: requested)
    }

    func testKeepsServerOrderRegardlessOfLibraryOrder() {
        let sage = result(ids: ["c", "a", "b"], resolved: ["a", "b", "c"], requested: 3)
        XCTAssertEqual(sage.tracks.map(\.id), ["c", "a", "b"])
        XCTAssertNil(sage.notice)
        XCTAssertFalse(sage.isEmpty)
        XCTAssertEqual(sage.description, "desc")
    }

    func testDropsUnresolvedIDsPreservingOrder() {
        let sage = result(ids: ["d", "x", "b", "y", "a"], resolved: ["a", "b", "d"], requested: 5)
        XCTAssertEqual(sage.tracks.map(\.id), ["d", "b", "a"])
        XCTAssertEqual(sage.notice, .missingFromLibrary(found: 3, picked: 5))
    }

    func testDropsRepeatedAndEmptyIDs() {
        let sage = result(ids: ["a", "b", "a", "", "c", "b"], resolved: ["a", "b", "c", "c"], requested: 3)
        XCTAssertEqual(sage.tracks.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(sage.pickedCount, 3)
        XCTAssertNil(sage.notice)
    }

    func testIgnoresTracksTheServerDidNotPick() {
        let sage = result(ids: ["a"], resolved: ["z", "a"], requested: 1)
        XCTAssertEqual(sage.tracks.map(\.id), ["a"])
    }

    func testFewerMatchesThanRequested() {
        let sage = result(ids: ["a", "b"], resolved: ["a", "b"], requested: 30)
        XCTAssertEqual(sage.notice, .fewerMatches(found: 2, requested: 30))
    }

    func testMissingFromLibraryWinsOverFewerMatches() {
        let sage = result(ids: ["a", "b", "c"], resolved: ["a"], requested: 30)
        XCTAssertEqual(sage.notice, .missingFromLibrary(found: 1, picked: 3))
    }

    func testNoNoticeWhenServerReturnsMoreThanRequested() {
        let sage = result(ids: ["a", "b", "c"], resolved: ["a", "b", "c"], requested: 2)
        XCTAssertNil(sage.notice)
    }

    func testEmptyWhenNothingResolves() {
        let sage = result(ids: ["a", "b"], resolved: [], requested: 15)
        XCTAssertTrue(sage.isEmpty)
        XCTAssertNil(sage.notice)
        XCTAssertEqual(sage.pickedCount, 2)
    }

    func testTitleFallsBackWhenBlank() {
        XCTAssertEqual(result(ids: [], resolved: [], requested: 1, title: "  \n").title, SageResult.fallbackTitle)
        XCTAssertEqual(result(ids: [], resolved: [], requested: 1, title: " Rainy Jazz ").title, "Rainy Jazz")
    }

    func testTotalDuration() {
        let sage = SageResult(
            title: "t", description: "", itemIDs: ["a", "b", "x"],
            resolved: [track("a", duration: 60), track("b", duration: 90.5)], requestedCount: 3
        )
        XCTAssertEqual(sage.totalDuration, 150.5, accuracy: 0.001)
    }
}

final class SageProgressTests: XCTestCase {
    func testFractionStartsAtZeroAndNeverReachesCeiling() {
        XCTAssertEqual(SageProgress.estimatedFraction(elapsed: 0), 0)
        XCTAssertEqual(SageProgress.estimatedFraction(elapsed: -3), 0)
        XCTAssertLessThanOrEqual(SageProgress.estimatedFraction(elapsed: 120), SageProgress.ceiling)
        XCTAssertLessThan(SageProgress.ceiling, 1)
    }

    func testFractionIsMonotonic() {
        var previous = -1.0
        for step in 0...240 {
            let value = SageProgress.estimatedFraction(elapsed: Double(step) * 0.5)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    func testFractionShowsVisibleProgressEarly() {
        XCTAssertGreaterThan(SageProgress.estimatedFraction(elapsed: 3), 0.2)
        XCTAssertLessThan(SageProgress.estimatedFraction(elapsed: 3), 0.5)
        XCTAssertGreaterThan(SageProgress.estimatedFraction(elapsed: 15), 0.7)
    }

    func testStages() {
        XCTAssertEqual(SageProgress.stage(elapsed: 0), .sending)
        XCTAssertEqual(SageProgress.stage(elapsed: 1.4), .sending)
        XCTAssertEqual(SageProgress.stage(elapsed: 1.5), .interpreting)
        XCTAssertEqual(SageProgress.stage(elapsed: 7.9), .interpreting)
        XCTAssertEqual(SageProgress.stage(elapsed: 8), .matching)
        XCTAssertEqual(SageProgress.stage(elapsed: 19.9), .matching)
        XCTAssertEqual(SageProgress.stage(elapsed: 20), .takingLong)
        XCTAssertEqual(SageProgress.stage(elapsed: 110), .takingLong)
    }
}
