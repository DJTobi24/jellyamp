import XCTest
import JellyfinBackend
import JellyampCore

/// Everything that is fetched by URL or per track: lyrics, artwork, audio.
final class MediaLiveTests: LiveTestCase {
    // MARK: Lyrics

    func testFirstTrackOfEveryAlbumHasSyncedLyrics() async throws {
        let lyricsAPI = LyricsAPI(session: session)
        for spec in Library.albums {
            let tracks = context.tracksByAlbum[spec.title]!
            let fetched = try await library.lyrics(forTrack: tracks[0].id)
            let timeline = try XCTUnwrap(fetched, "no lyrics for \(tracks[0].title)")
            XCTAssertTrue(timeline.isSynced, spec.title)
            XCTAssertEqual(timeline.lines.count, 6, spec.title)
            XCTAssertEqual(timeline.lines.map { $0.start ?? -1 }, [0, 5, 10, 15, 20, 25], spec.title)
            XCTAssertEqual(timeline.lines.first?.text, "This is a generated test track")
            XCTAssertEqual(timeline.lines.last?.text, "Goodbye")
            XCTAssertEqual(timeline.activeLineIndex(at: 12), 2)

            // No lyrics is nil, not an error — for the protocol method and the API class alike.
            let none = try await library.lyrics(forTrack: tracks[1].id)
            XCTAssertNil(none, tracks[1].title)
            let direct = try await lyricsAPI.lyrics(forTrack: tracks[1].id)
            XCTAssertNil(direct)
        }
        let unknown = try await library.lyrics(forTrack: Library.unknownID)
        XCTAssertNil(unknown)
        let album = try await library.lyrics(forTrack: context.album("Voltage").id)
        XCTAssertNil(album, "an album has no lyrics")
    }

    // MARK: Images

    private func assertIsJPEG(_ response: Response, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(response.status, 200, message, file: file, line: line)
        XCTAssertEqual(response.contentType, "image/jpeg", message, file: file, line: line)
        XCTAssertEqual(Array(response.body.prefix(2)), [0xFF, 0xD8], "not a JPEG: \(message)", file: file, line: line)
        XCTAssertGreaterThan(response.body.count, 500, message, file: file, line: line)
    }

    func testAlbumImageURLsReturnImagesWithAndWithoutTag() async throws {
        for spec in Library.albums {
            let album = context.album(spec.title)
            let tagged = try await fetch(ImageURLBuilder.url(itemID: album.id, tag: album.imageTag, maxWidth: 300, session: session))
            assertIsJPEG(tagged, "\(spec.title) with tag")
            let untagged = try await fetch(ImageURLBuilder.url(itemID: album.id, tag: nil, maxWidth: 300, session: session))
            assertIsJPEG(untagged, "\(spec.title) without tag")
            // The tag is a cache key, not a selector: same picture either way.
            XCTAssertEqual(tagged.body, untagged.body, spec.title)
        }
    }

    func testImageWidthIsHonoured() async throws {
        let album = context.album("Low Tide")
        let small = try await fetch(ImageURLBuilder.url(itemID: album.id, tag: album.imageTag, maxWidth: 60, session: session))
        let large = try await fetch(ImageURLBuilder.url(itemID: album.id, tag: album.imageTag, maxWidth: 600, session: session))
        assertIsJPEG(large, "600")
        XCTAssertEqual(small.status, 200)
        XCTAssertLessThan(small.body.count, large.body.count)
        XCTAssertEqual(Self.jpegSize(small.body)?.width, 60)
        XCTAssertEqual(Self.jpegSize(large.body)?.width, 600)
    }

    func testTrackImageFallsBackToAlbumArt() async throws {
        for title in ["Power On", "Allegro in D", "Phosphor", "Last Call", "Sampler Outro"] {
            let track = context.track(title)
            let url = try XCTUnwrap(ImageURLBuilder.trackImageURL(track: track, maxWidth: 300, session: session))
            let image = try await fetch(url)
            assertIsJPEG(image, title)
            let album = context.albums[track.albumName ?? ""]!
            let albumImage = try await fetch(ImageURLBuilder.url(itemID: album.id, tag: album.imageTag, maxWidth: 300, session: session))
            XCTAssertEqual(image.body, albumImage.body, title)
        }
    }

    func testMissingImagesAre404() async throws {
        // The library has album covers only: no backdrops, no artist pictures.
        let album = context.album("Voltage")
        let backdrop = try await fetch(ImageURLBuilder.url(itemID: album.id, tag: nil, type: .backdrop, maxWidth: 300, session: session))
        XCTAssertEqual(backdrop.status, 404)
        let unknown = try await fetch(ImageURLBuilder.url(itemID: Library.unknownID, tag: nil, maxWidth: 300, session: session))
        XCTAssertEqual(unknown.status, 404)
        for artist in context.artists.values where artist.imageTag == nil {
            let picture = try await fetch(ImageURLBuilder.url(itemID: artist.id, tag: nil, maxWidth: 300, session: session))
            XCTAssertEqual(picture.status, 404, artist.name)
        }
    }

    /// Width/height from the first SOFn marker.
    static func jpegSize(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data)
        var index = 2
        while index + 9 < bytes.count, bytes[index] == 0xFF {
            let marker = bytes[index + 1]
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            if (0xC0...0xCF).contains(marker), marker != 0xC4, marker != 0xC8, marker != 0xCC {
                let height = Int(bytes[index + 5]) << 8 | Int(bytes[index + 6])
                let width = Int(bytes[index + 7]) << 8 | Int(bytes[index + 8])
                return (width, height)
            }
            index += 2 + length
        }
        return nil
    }

    // MARK: Audio

    /// One track per container/codec in the library.
    private var oneTrackPerCodec: [(track: Track, mime: String, magic: [UInt8], magicOffset: Int)] {
        [
            (context.track("Power On"), "audio/mpeg", Array("ID3".utf8), 0),
            (context.track("Allegro in D"), "audio/flac", Array("fLaC".utf8), 0),
            (context.track("Phosphor"), "audio/mp4", Array("ftyp".utf8), 4),
            (context.track("Last Call"), "audio/ogg", Array("OggS".utf8), 0),
        ]
    }

    func testDirectPlayURLsServeTheOriginalFileForEveryCodec() async throws {
        for (track, mime, magic, offset) in oneTrackPerCodec {
            let url = StreamURLBuilder.url(for: track.id, request: .directPlay, session: session)
            let whole = try await fetch(url)
            XCTAssertEqual(whole.status, 200, track.title)
            XCTAssertEqual(whole.contentType, mime, track.title)
            XCTAssertEqual(whole.headers["accept-ranges"], "bytes", track.title)
            XCTAssertEqual(Array(whole.body.dropFirst(offset).prefix(magic.count)), magic, "\(track.title) is not a \(mime) file")
            XCTAssertGreaterThan(whole.body.count, 50_000, track.title)
            // File size agrees with the bitrate the API reported.
            let expectedBytes = Double(track.bitrate ?? 0) / 8 * track.duration
            XCTAssertEqual(Double(whole.body.count), expectedBytes, accuracy: expectedBytes * 0.15 + 20_000, track.title)

            // Byte ranges: what seeking and resumable downloads rely on.
            let part = try await fetch(url, headers: ["Range": "bytes=1000-1999"])
            XCTAssertEqual(part.status, 206, track.title)
            XCTAssertEqual(part.contentType, mime, track.title)
            XCTAssertEqual(part.headers["content-range"], "bytes 1000-1999/\(whole.body.count)", track.title)
            XCTAssertEqual(part.body, whole.body.subdata(in: 1000..<2000), track.title)
            let tail = try await fetch(url, headers: ["Range": "bytes=\(whole.body.count - 100)-"])
            XCTAssertEqual(tail.status, 206, track.title)
            XCTAssertEqual(tail.body, whole.body.suffix(100), track.title)
        }
    }

    func testStreamURLsNeedTheToken() async throws {
        let track = context.track("Power On")
        var signedOut = session
        signedOut.accessToken = nil
        let direct = try await fetch(StreamURLBuilder.url(for: track.id, request: .directPlay, session: signedOut))
        XCTAssertEqual(direct.status, 401)
        var revoked = session
        revoked.accessToken = "0123456789abcdef0123456789abcdef"
        let transcode = try await fetch(StreamURLBuilder.url(
            for: track.id, request: .transcode(codec: "aac", container: "ts", maxBitrate: 128_000), session: revoked))
        XCTAssertEqual(transcode.status, 401)
        let unknown = try await fetch(StreamURLBuilder.url(for: Library.unknownID, request: .directPlay, session: session))
        XCTAssertEqual(unknown.status, 404)
    }

    /// Segment URLs of an HLS media playlist, resolved against the playlist URL.
    private func segments(of playlist: Response, at url: URL) throws -> [URL] {
        let text = try XCTUnwrap(String(data: playlist.body, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("#EXTM3U"), text)
        return text.split(separator: "\n")
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .compactMap { URL(string: String($0), relativeTo: url)?.absoluteURL }
    }

    private func stopTranscode(of url: URL) async {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = items.filter { ["deviceId", "playSessionId"].contains($0.name) }
        _ = try? await raw("DELETE", "Videos/ActiveEncodings", query: query)
    }

    func testTranscodeURLsServeHLSAudioForEveryCodec() async throws {
        for (track, _, _, _) in oneTrackPerCodec {
            let url = StreamURLBuilder.url(
                for: track.id,
                request: .transcode(codec: "aac", container: "ts", maxBitrate: 128_000),
                session: session
            )
            try await withCleanup({
                let playlist = try await self.fetch(url)
                XCTAssertEqual(playlist.status, 200, track.title)
                XCTAssertTrue(playlist.contentType.lowercased().contains("mpegurl"), "\(track.title): \(playlist.contentType)")
                let segments = try self.segments(of: playlist, at: url)
                // 30 s of audio in 3 s segments (mp3 sources run 30.04 s: an 11th, short one).
                XCTAssertTrue((10...11).contains(segments.count), "\(track.title): \(segments.count) segments")
                for segmentURL in [segments[0], segments[4]] {
                    let segment = try await self.fetch(segmentURL)
                    XCTAssertEqual(segment.status, 200, track.title)
                    XCTAssertEqual(segment.contentType, "video/mp2t", track.title)
                    // MPEG-TS: 188-byte packets starting with a 0x47 sync byte.
                    XCTAssertEqual(segment.body.first, 0x47, track.title)
                    XCTAssertEqual(segment.body.count % 188, 0, track.title)
                    // 3 s at 128 kb/s are 48 kB; allow container overhead and encoder slack.
                    XCTAssertTrue((20_000...120_000).contains(segment.body.count), "\(track.title): \(segment.body.count) bytes")
                }
            }, cleanup: {
                await self.stopTranscode(of: url)
            })
        }
    }

    func testSeekingAnHLSURLKeepsItPlayable() async throws {
        // Regression: `url(_:seekingTo:)` used to add `startTimeTicks` to the
        // HLS URL. The server then still returns the playlist of the whole
        // track, copies the parameter onto every segment URL — and answers
        // each segment with 400 "StartTimeTicks is not allowed".
        let track = context.track("Allegro in D")
        let base = StreamURLBuilder.url(
            for: track.id, request: .transcode(codec: "aac", container: "ts", maxBitrate: 128_000), session: session)
        let seeked = StreamURLBuilder.url(base, seekingTo: 15)
        XCTAssertEqual(seeked, base, "HLS is seeked by the player, not by the URL")
        try await withCleanup({
            let playlist = try await self.fetch(seeked)
            XCTAssertEqual(playlist.status, 200)
            let segments = try self.segments(of: playlist, at: seeked)
            XCTAssertEqual(segments.count, 10)
            let segment = try await self.fetch(segments[5])
            XCTAssertEqual(segment.status, 200)
            XCTAssertEqual(segment.body.first, 0x47)

            // What the server does with the parameter, so nobody adds it back.
            var broken = try XCTUnwrap(URLComponents(url: base, resolvingAgainstBaseURL: false))
            broken.queryItems = (broken.queryItems ?? []) + [URLQueryItem(name: "startTimeTicks", value: "150000000")]
            let brokenURL = try XCTUnwrap(broken.url)
            let brokenPlaylist = try await self.fetch(brokenURL)
            XCTAssertEqual(brokenPlaylist.status, 200)
            let brokenSegments = try self.segments(of: brokenPlaylist, at: brokenURL)
            XCTAssertEqual(brokenSegments.count, 10, "still the whole track")
            let refused = try await self.fetch(brokenSegments[5])
            XCTAssertEqual(refused.status, 400)
        }, cleanup: {
            await self.stopTranscode(of: seeked)
        })
    }

    func testProgressiveTranscodeStartsAtStartTime() async throws {
        // The progressive transcode is the stream `startTimeTicks` really
        // seeks in: it is not byte-seekable, so seeking = asking again.
        for (track, _, _, _) in oneTrackPerCodec {
            let whole = StreamURLBuilder.progressiveTranscodeURL(
                for: track.id, codec: "aac", container: "aac", maxBitrate: 128_000, startTime: 0, session: session)
            let fromTwenty = StreamURLBuilder.progressiveTranscodeURL(
                for: track.id, codec: "aac", container: "aac", maxBitrate: 128_000, startTime: 20, session: session)
            try await withCleanup({
                let full = try await self.fetch(whole)
                XCTAssertEqual(full.status, 200, track.title)
                XCTAssertEqual(full.contentType, "audio/aac", track.title)
                // ADTS frames start with the 12-bit sync word 0xFFF.
                XCTAssertEqual(full.body.first, 0xFF, track.title)
                XCTAssertEqual((full.body.dropFirst().first ?? 0) & 0xF0, 0xF0, track.title)
                // 30 s at 128 kb/s are 480 kB.
                XCTAssertEqual(Double(full.body.count), 480_000, accuracy: 120_000, track.title)

                let rest = try await self.fetch(fromTwenty)
                XCTAssertEqual(rest.status, 200, track.title)
                XCTAssertEqual(rest.body.first, 0xFF, track.title)
                // The last 10 of 30 seconds: a third of the bytes.
                XCTAssertEqual(Double(rest.body.count) / Double(full.body.count), 1.0 / 3, accuracy: 0.08, track.title)

                // `url(_:seekingTo:)` produces the same request.
                let viaSeek = StreamURLBuilder.url(whole, seekingTo: 20)
                XCTAssertEqual(
                    URLComponents(url: viaSeek, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "startTimeTicks" }?.value,
                    "200000000")
            }, cleanup: {
                await self.stopTranscode(of: whole)
                await self.stopTranscode(of: fromTwenty)
            })
        }
    }
}
