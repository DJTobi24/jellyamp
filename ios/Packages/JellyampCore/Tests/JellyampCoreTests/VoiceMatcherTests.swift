import XCTest
@testable import JellyampCore

final class VoiceTextNormalizerTests: XCTestCase {
    func testFoldsCaseDiacriticsAndPunctuation() {
        XCTAssertEqual(VoiceTextNormalizer.normalize("Björk"), "bjork")
        XCTAssertEqual(VoiceTextNormalizer.normalize("Sigur Rós"), "sigur ros")
        XCTAssertEqual(VoiceTextNormalizer.normalize("Motörhead!"), "motorhead")
        XCTAssertEqual(VoiceTextNormalizer.normalize("Die Ärzte"), "arzte")
        XCTAssertEqual(VoiceTextNormalizer.normalize("Straße"), "strasse")
        XCTAssertEqual(VoiceTextNormalizer.normalize("Røyksopp"), "royksopp")
        XCTAssertEqual(VoiceTextNormalizer.normalize("  Hello,   World  "), "hello world")
    }

    func testApostrophesAndDotsJoinWords() {
        XCTAssertEqual(VoiceTextNormalizer.normalize("Don't Stop Believin'"), "dont stop believin")
        XCTAssertEqual(VoiceTextNormalizer.normalize("R.E.M."), "rem")
        XCTAssertEqual(VoiceTextNormalizer.normalize("Guns N’ Roses"), "guns n roses")
    }

    func testAmpersandBecomesAnd() {
        XCTAssertEqual(VoiceTextNormalizer.normalize("Simon & Garfunkel"), "simon and garfunkel")
        XCTAssertEqual(VoiceTextNormalizer.normalize("Simon and Garfunkel"), "simon and garfunkel")
    }

    func testLeadingArticleIsDroppedOnlyWhenWordsRemain() {
        XCTAssertEqual(VoiceTextNormalizer.normalize("The Beatles"), "beatles")
        XCTAssertEqual(VoiceTextNormalizer.normalize("A Perfect Circle"), "perfect circle")
        XCTAssertEqual(VoiceTextNormalizer.normalize("The The"), "the")
        XCTAssertEqual(VoiceTextNormalizer.normalize("The"), "the")
        // Articles inside the title stay.
        XCTAssertEqual(VoiceTextNormalizer.normalize("Rage Against the Machine"), "rage against the machine")
    }

    func testCompactIgnoresSpacing() {
        XCTAssertEqual(VoiceTextNormalizer.compact("AC/DC"), "acdc")
        XCTAssertEqual(VoiceTextNormalizer.compact("ACDC"), "acdc")
    }

    func testEditionSuffixStripping() {
        XCTAssertEqual(VoiceTextNormalizer.strippingEditionSuffix("Abbey Road (Remastered 2019)"), "Abbey Road")
        XCTAssertEqual(VoiceTextNormalizer.strippingEditionSuffix("Kind of Blue [Legacy Edition]"), "Kind of Blue")
        XCTAssertEqual(VoiceTextNormalizer.strippingEditionSuffix("Hurt - Live"), "Hurt")
        // Nothing left → keep the original.
        XCTAssertEqual(VoiceTextNormalizer.strippingEditionSuffix("(What's the Story) Morning Glory?"), "(What's the Story) Morning Glory?")
        XCTAssertEqual(VoiceTextNormalizer.strippingEditionSuffix("Blue"), "Blue")
    }

    func testIndexLetter() {
        XCTAssertEqual(VoiceTextNormalizer.indexLetter("The Beatles"), "B")
        XCTAssertEqual(VoiceTextNormalizer.indexLetter("Ärzte"), "A")
        XCTAssertEqual(VoiceTextNormalizer.indexLetter("2Pac"), "#")
        XCTAssertEqual(VoiceTextNormalizer.indexLetter("!!!"), "#")
        XCTAssertEqual(VoiceTextNormalizer.indexLetter(""), "#")
    }
}

final class VoiceEntityIdentifierTests: XCTestCase {
    func testRoundTripKeepsColonsInName() {
        let identifier = VoiceEntityIdentifier(kind: .album, itemID: "0af1", name: "Symphony No. 5: Allegro")
        XCTAssertEqual(identifier.rawValue, "album:0af1:Symphony No. 5: Allegro")
        XCTAssertEqual(VoiceEntityIdentifier(rawValue: identifier.rawValue), identifier)
        XCTAssertEqual(VoiceEntityIdentifier(rawValue: "genre:g1:")?.name, "")
    }

    func testRejectsMalformedIdentifiers() {
        XCTAssertNil(VoiceEntityIdentifier(rawValue: ""))
        XCTAssertNil(VoiceEntityIdentifier(rawValue: "album:0af1"))
        XCTAssertNil(VoiceEntityIdentifier(rawValue: "podcast:0af1:Name"))
        XCTAssertNil(VoiceEntityIdentifier(rawValue: "album::Name"))
    }
}

final class VoiceQueryParserTests: XCTestCase {
    func testStripsCommandAndFiller() {
        XCTAssertEqual(VoiceQueryParser.parse("Play some Miles Davis").text, "Miles Davis")
        XCTAssertEqual(VoiceQueryParser.parse("listen to Björk").text, "Björk")
        XCTAssertEqual(VoiceQueryParser.parse("Miles Davis").text, "Miles Davis")
    }

    func testKindHints() {
        let album = VoiceQueryParser.parse("play the album Kind of Blue")
        XCTAssertEqual(album.text, "Kind of Blue")
        XCTAssertEqual(album.kindHint, .album)

        XCTAssertEqual(VoiceQueryParser.parse("the song Hurt").kindHint, .track)
        XCTAssertEqual(VoiceQueryParser.parse("my playlist Road Trip").kindHint, .playlist)
        XCTAssertEqual(VoiceQueryParser.parse("my playlist Road Trip").text, "Road Trip")

        let artist = VoiceQueryParser.parse("songs by Radiohead")
        XCTAssertEqual(artist.text, "Radiohead")
        XCTAssertEqual(artist.kindHint, .artist)
        // "by" was consumed by the hint — no title/artist split.
        XCTAssertNil(artist.artistPart)
    }

    func testSuffixHints() {
        let genre = VoiceQueryParser.parse("play jazz music")
        XCTAssertEqual(genre.text, "jazz")
        XCTAssertEqual(genre.kindHint, .genre)

        let playlist = VoiceQueryParser.parse("my chill playlist")
        XCTAssertEqual(playlist.text, "chill")
        XCTAssertEqual(playlist.kindHint, .playlist)

        let songs = VoiceQueryParser.parse("Beatles songs")
        XCTAssertEqual(songs.text, "Beatles")
        XCTAssertNil(songs.kindHint)
    }

    func testNeverConsumesTheWholeRequest() {
        XCTAssertEqual(VoiceQueryParser.parse("Play").text, "Play")
        XCTAssertEqual(VoiceQueryParser.parse("Album").text, "Album")
        XCTAssertEqual(VoiceQueryParser.parse("Music").text, "Music")
        XCTAssertEqual(VoiceQueryParser.parse("").text, "")
    }

    func testBySplitIsOnlyACandidate() {
        let query = VoiceQueryParser.parse("Hurt by Johnny Cash")
        XCTAssertEqual(query.text, "Hurt by Johnny Cash")
        XCTAssertEqual(query.titlePart, "Hurt")
        XCTAssertEqual(query.artistPart, "Johnny Cash")

        let stand = VoiceQueryParser.parse("Stand by Me")
        XCTAssertEqual(stand.text, "Stand by Me")
        XCTAssertEqual(stand.titlePart, "Stand")
        XCTAssertEqual(stand.artistPart, "Me")
    }
}

final class VoiceMatcherTests: XCTestCase {
    private let matcher = VoiceMatcher()

    private func artist(_ name: String, id: String? = nil) -> VoiceCandidate {
        VoiceCandidate(kind: .artist, id: id ?? "artist-\(name)", title: name)
    }

    private func album(_ title: String, by artistName: String, id: String? = nil) -> VoiceCandidate {
        VoiceCandidate(kind: .album, id: id ?? "album-\(title)-\(artistName)", title: title, artistName: artistName)
    }

    private func track(_ title: String, by artistName: String, id: String? = nil) -> VoiceCandidate {
        VoiceCandidate(kind: .track, id: id ?? "track-\(title)-\(artistName)", title: title, artistName: artistName)
    }

    private func playlist(_ name: String) -> VoiceCandidate {
        VoiceCandidate(kind: .playlist, id: "playlist-\(name)", title: name)
    }

    private func genre(_ name: String) -> VoiceCandidate {
        VoiceCandidate(kind: .genre, id: "genre-\(name)", title: name)
    }

    private func resolvedTitle(_ spoken: String, _ candidates: [VoiceCandidate]) -> VoiceCandidate? {
        if case .match(let match) = matcher.resolve(spoken: spoken, candidates: candidates) {
            return match.candidate
        }
        return nil
    }

    // MARK: Title scoring tiers

    func testScoreTiersAreOrdered() {
        let exact = VoiceMatcher.titleScore(spoken: "abbey road", title: "Abbey Road")
        let edition = VoiceMatcher.titleScore(spoken: "abbey road", title: "Abbey Road (Remastered)")
        let prefix = VoiceMatcher.titleScore(spoken: "abbey road", title: "Abbey Road Sessions")
        let contained = VoiceMatcher.titleScore(spoken: "abbey road", title: "Live at Abbey Road")
        let fuzzy = VoiceMatcher.titleScore(spoken: "abby rode", title: "Abbey Road")
        let unrelated = VoiceMatcher.titleScore(spoken: "abbey road", title: "Dark Side of the Moon")
        XCTAssertEqual(exact, 1.0)
        XCTAssertGreaterThan(exact, edition)
        XCTAssertGreaterThan(edition, prefix)
        XCTAssertGreaterThan(prefix, contained)
        XCTAssertGreaterThan(contained, fuzzy)
        XCTAssertGreaterThanOrEqual(fuzzy, 0.5)
        XCTAssertEqual(unrelated, 0)
    }

    func testSpacingAndPunctuationVariantsMatch() {
        XCTAssertGreaterThanOrEqual(VoiceMatcher.titleScore(spoken: "ACDC", title: "AC/DC"), 0.95)
        XCTAssertGreaterThanOrEqual(VoiceMatcher.titleScore(spoken: "REM", title: "R.E.M."), 0.95)
        XCTAssertGreaterThanOrEqual(VoiceMatcher.titleScore(spoken: "day dream", title: "Daydream"), 0.95)
        XCTAssertEqual(VoiceMatcher.titleScore(spoken: "beatles", title: "The Beatles"), 1.0)
        XCTAssertEqual(VoiceMatcher.titleScore(spoken: "bjork", title: "Björk"), 1.0)
    }

    func testOneUnrelatedWordSinksAFuzzyMatch() {
        XCTAssertEqual(VoiceMatcher.titleScore(spoken: "blue zebra", title: "Kind of Blue"), 0)
        XCTAssertEqual(VoiceMatcher.titleScore(spoken: "", title: "Anything"), 0)
        XCTAssertEqual(VoiceMatcher.titleScore(spoken: "anything", title: ""), 0)
    }

    func testSimilarity() {
        XCTAssertEqual(VoiceMatcher.similarity("kitten", "kitten"), 1)
        XCTAssertEqual(VoiceMatcher.similarity("", ""), 1)
        XCTAssertEqual(VoiceMatcher.similarity("abc", ""), 0)
        XCTAssertEqual(VoiceMatcher.similarity("kitten", "sitting"), 1 - 3.0 / 7.0, accuracy: 1e-9)
    }

    // MARK: Resolution

    func testNoCandidatesOrNoMatch() {
        XCTAssertEqual(matcher.resolve(spoken: "radiohead", candidates: []), .none)
        XCTAssertEqual(matcher.resolve(spoken: "radiohead", candidates: [artist("Miles Davis")]), .none)
    }

    func testExactArtistBeatsSelfTitledAlbumWithoutAsking() {
        let candidates = [
            album("Weezer", by: "Weezer"),
            track("Weezer", by: "Someone Else"),
            artist("Weezer"),
        ]
        XCTAssertEqual(resolvedTitle("Weezer", candidates)?.kind, .artist)
    }

    func testKindHintOverridesPriority() {
        let candidates = [artist("Weezer"), album("Weezer", by: "Weezer")]
        XCTAssertEqual(resolvedTitle("the album Weezer", candidates)?.kind, .album)
        // A hint for a kind that does not exist must not hide the real match.
        XCTAssertEqual(resolvedTitle("Weezer music", candidates)?.kind, .artist)
    }

    func testKindPriorityOrder() {
        let all = [track("Chill", by: "X"), album("Chill", by: "Y"), genre("Chill"), playlist("Chill"), artist("Chill")]
        let ranked = matcher.rank(spoken: "chill", candidates: all).map(\.candidate.kind)
        XCTAssertEqual(ranked, [.artist, .playlist, .genre, .album, .track])
    }

    func testSameKindTieIsAmbiguous() {
        let candidates = [
            album("Greatest Hits", by: "Queen"),
            album("Greatest Hits", by: "ABBA"),
            artist("Unrelated"),
        ]
        guard case .ambiguous(let choices) = matcher.resolve(spoken: "greatest hits", candidates: candidates) else {
            return XCTFail("expected a disambiguation list")
        }
        XCTAssertEqual(choices.count, 2)
        // Deterministic order among equals: by id.
        XCTAssertEqual(choices.map(\.candidate.artistName), ["ABBA", "Queen"])
    }

    func testArtistPartSettlesSameTitle() {
        let candidates = [
            album("Greatest Hits", by: "Queen"),
            album("Greatest Hits", by: "ABBA"),
        ]
        XCTAssertEqual(resolvedTitle("Greatest Hits by Queen", candidates)?.artistName, "Queen")

        let tracks = [track("Hurt", by: "Nine Inch Nails"), track("Hurt", by: "Johnny Cash")]
        XCTAssertEqual(resolvedTitle("Hurt by Johnny Cash", tracks)?.artistName, "Johnny Cash")
    }

    func testTitleContainingByStillMatchesExactly() {
        let candidates = [track("Stand by Me", by: "Ben E. King"), track("Stand", by: "R.E.M.")]
        XCTAssertEqual(resolvedTitle("Stand by Me", candidates)?.title, "Stand by Me")
    }

    func testExactBeatsLongerTitles() {
        let candidates = [
            album("Blue Train", by: "John Coltrane"),
            album("Blue", by: "Joni Mitchell"),
            album("Kind of Blue", by: "Miles Davis"),
        ]
        XCTAssertEqual(resolvedTitle("blue", candidates)?.title, "Blue")
    }

    func testRemasterMatchesWithoutSayingIt() {
        let candidates = [album("Abbey Road (Remastered 2019)", by: "The Beatles"), album("Let It Be", by: "The Beatles")]
        XCTAssertEqual(resolvedTitle("Abbey Road", candidates)?.title, "Abbey Road (Remastered 2019)")
    }

    func testMisheardNameStillResolvesWhenAlone() {
        let candidates = [artist("Radiohead"), artist("Miles Davis"), artist("Portishead")]
        XCTAssertEqual(resolvedTitle("radio head", candidates)?.title, "Radiohead")
        XCTAssertEqual(resolvedTitle("Myles Davis", candidates)?.title, "Miles Davis")
    }

    func testCloseFuzzyMatchesAskInsteadOfGuessing() {
        let candidates = [album("Live in Paris", by: "A"), album("Live in Parma", by: "B")]
        guard case .ambiguous(let choices) = matcher.resolve(spoken: "live in pari", candidates: candidates) else {
            return XCTFail("expected a disambiguation list")
        }
        XCTAssertEqual(choices.first?.candidate.title, "Live in Paris")
    }

    func testPrefixMatchPrefersShorterTitle() {
        let candidates = [
            album("Random Access Memories (Drumless Edition) Bonus", by: "Daft Punk", id: "b"),
            album("Random Access Memories Live", by: "Daft Punk", id: "a"),
        ]
        let ranked = matcher.rank(spoken: "random access", candidates: candidates)
        XCTAssertEqual(ranked.first?.candidate.id, "a")
    }

    func testDuplicatesAreCollapsedAndChoicesCapped() {
        var candidates: [VoiceCandidate] = []
        for index in 0..<8 {
            candidates.append(album("Best Of", by: "Artist \(index)", id: "id-\(index)"))
        }
        candidates.append(album("Best Of", by: "Artist 0", id: "id-0"))
        XCTAssertEqual(matcher.rank(spoken: "best of", candidates: candidates).count, 8)
        guard case .ambiguous(let choices) = matcher.resolve(spoken: "best of", candidates: candidates) else {
            return XCTFail("expected a disambiguation list")
        }
        XCTAssertEqual(choices.count, 5)
    }

    func testRankingIsStableAcrossInputOrder() {
        let candidates = [
            artist("Blue"), album("Blue", by: "Joni Mitchell"), track("Blue", by: "Eiffel 65"),
            album("Kind of Blue", by: "Miles Davis"), playlist("Blue Monday"),
        ]
        let forward = matcher.rank(spoken: "blue", candidates: candidates)
        let backward = matcher.rank(spoken: "blue", candidates: candidates.reversed())
        XCTAssertEqual(forward, backward)
    }
}
