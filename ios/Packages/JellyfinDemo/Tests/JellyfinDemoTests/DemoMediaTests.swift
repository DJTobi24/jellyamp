import XCTest
@testable import JellyfinDemo

/// The generated media must be what it claims to be: valid PNG, valid ADTS.
final class DemoMediaTests: XCTestCase {
    // MARK: - Audio

    func testEveryLoopIsCleanADTSOfTheSameLength() {
        for style in DemoAudio.Style.allCases {
            let loops = DemoAudio.loopData(for: style)
            XCTAssertEqual(loops.count, DemoAudio.loopsPerStyle)
            for (index, loop) in loops.enumerated() {
                XCTAssertFalse(loop.isEmpty, "\(style)-\(index) is missing from the bundle")
                XCTAssertEqual(DemoAudio.adtsFrameCount(in: loop), DemoAudio.framesPerLoop, "\(style)-\(index)")
                // ADTS header: AAC-LC, 44.1 kHz, stereo — what the items claim.
                let header = [UInt8](loop.prefix(4))
                XCTAssertEqual(header[0], 0xFF)
                XCTAssertEqual(header[1] & 0xF6, 0xF0, "MPEG-4, layer 0")
                XCTAssertEqual(header[2] >> 6, 1, "profile AAC-LC")
                XCTAssertEqual((header[2] >> 2) & 0x0F, 4, "sampling frequency index of 44.1 kHz")
                XCTAssertEqual(((header[2] & 0x01) << 2) | (header[3] >> 6), 2, "channel configuration stereo")
            }
        }
    }

    func testTrackAudioMatchesItsAdvertisedDurationAndSize() throws {
        for track in [DemoCatalog.tracks[0], DemoCatalog.tracks[17], DemoCatalog.tracks[59]] {
            let data = try XCTUnwrap(DemoAudio.data(forTrackID: track.id))
            XCTAssertEqual(data.count, DemoAudio.byteCount(of: track))
            let frames = try XCTUnwrap(DemoAudio.adtsFrameCount(in: data))
            XCTAssertEqual(frames, track.loopCount * DemoAudio.framesPerLoop)
            let seconds = Double(frames * DemoAudio.samplesPerFrame) / Double(DemoAudio.sampleRate)
            XCTAssertEqual(seconds, track.duration, accuracy: 0.001)
            XCTAssertEqual(Double(DemoAudio.bitrate(of: track)), Double(data.count) * 8 / seconds, accuracy: 1)
        }
        XCTAssertNil(DemoAudio.data(forTrackID: "nope"))
    }

    func testTracksOfOneStyleAreArrangedDifferently() {
        let album = DemoCatalog.tracks.filter { $0.albumIndex == 0 }
        let arrangements = Set(album.map { DemoAudio.arrangement(of: $0).prefix(8).map(String.init).joined() })
        XCTAssertGreaterThan(arrangements.count, 1)
    }

    func testFrameCounterRejectsGarbage() {
        XCTAssertNil(DemoAudio.adtsFrameCount(in: Data([1, 2, 3, 4, 5, 6, 7, 8])))
        XCTAssertEqual(DemoAudio.adtsFrameCount(in: Data()), 0)
    }

    // MARK: - Artwork

    func testEveryItemHasACover() throws {
        let ids = DemoCatalog.albums.map(\.id) + DemoCatalog.artists.map(\.id) + DemoCatalog.playlists.map(\.id)
        var seen = Set<Data>()
        for id in ids {
            let png = try XCTUnwrap(DemoArtwork.png(forItemID: id, size: 64), id)
            let image = try PNGInspector(png)
            XCTAssertEqual(image.width, 64)
            XCTAssertEqual(image.height, 64)
            XCTAssertGreaterThan(image.distinctColors, 8, "cover of \(id) is flat")
            seen.insert(png)
        }
        XCTAssertEqual(seen.count, ids.count, "two items share a cover")
        XCTAssertNil(DemoArtwork.png(forItemID: DemoCatalog.tracks[0].id, size: 64))
    }

    func testCoverSizeIsClampedAndStable() throws {
        let id = DemoCatalog.albums[3].id
        XCTAssertEqual(try PNGInspector(XCTUnwrap(DemoArtwork.png(forItemID: id, size: 1))).width, DemoArtwork.minimumSize)
        XCTAssertEqual(try PNGInspector(XCTUnwrap(DemoArtwork.png(forItemID: id, size: 5000))).width, DemoArtwork.maximumSize)
        XCTAssertEqual(DemoArtwork.png(forItemID: id, size: 120), DemoArtwork.png(forItemID: id, size: 120))
        XCTAssertEqual(DemoArtwork.tag(forItemID: id).count, 32)
    }

    /// Not a test: writes every cover and one track per artist to
    /// `DEMO_EXPORT_DIR` so a change to the generators can be looked at and
    /// listened to (`DEMO_EXPORT_DIR=/tmp/demo swift test --filter testExportSamples`).
    func testExportSamples() throws {
        guard let path = ProcessInfo.processInfo.environment["DEMO_EXPORT_DIR"], !path.isEmpty else {
            throw XCTSkip("set DEMO_EXPORT_DIR to export the generated covers and audio")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for id in DemoCatalog.albums.map(\.id) + DemoCatalog.artists.map(\.id) + DemoCatalog.playlists.map(\.id) {
            try XCTUnwrap(DemoArtwork.png(forItemID: id, size: 480)).write(to: directory.appendingPathComponent("\(id).png"))
        }
        for artist in DemoCatalog.artists {
            let track = try XCTUnwrap(DemoCatalog.tracks.first { $0.artist.id == artist.id })
            try XCTUnwrap(DemoAudio.data(forTrackID: track.id)).write(to: directory.appendingPathComponent("\(artist.genre).aac"))
        }
    }

    func testPNGEncoderRoundTrips() throws {
        // 3×2: wider than tall, so swapped dimensions would show.
        let pixels: [UInt8] = [255, 0, 0, 0, 255, 0, 0, 0, 255, 10, 20, 30, 40, 50, 60, 70, 80, 90]
        let image = try PNGInspector(PNGEncoder.encode(rgb: pixels, width: 3, height: 2))
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.rgb, pixels)
    }
}

/// Reads back the subset of PNG that `PNGEncoder` writes, verifying every
/// checksum on the way (CRC-32 per chunk, Adler-32 of the pixel data).
struct PNGInspector {
    struct Malformed: Error, CustomStringConvertible {
        var description: String
    }

    var width = 0
    var height = 0
    var rgb: [UInt8] = []

    var distinctColors: Int {
        var colors = Set<UInt32>()
        var index = 0
        while index + 2 < rgb.count {
            colors.insert(UInt32(rgb[index]) << 16 | UInt32(rgb[index + 1]) << 8 | UInt32(rgb[index + 2]))
            index += 3
        }
        return colors.count
    }

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { throw Malformed(description: "signature") }
        var offset = 8
        var compressed: [UInt8] = []
        var sawEnd = false
        func be32(_ at: Int) -> Int {
            Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
        }
        while offset + 12 <= bytes.count {
            let length = be32(offset)
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            guard offset + 12 + length <= bytes.count else { throw Malformed(description: "truncated \(type)") }
            let payload = Array(bytes[(offset + 8)..<(offset + 8 + length)])
            let crc = UInt32(be32(offset + 8 + length))
            guard Self.crc32(Array(bytes[(offset + 4)..<(offset + 8 + length)])) == crc else { throw Malformed(description: "CRC of \(type)") }
            switch type {
            case "IHDR":
                width = Int(payload[0]) << 24 | Int(payload[1]) << 16 | Int(payload[2]) << 8 | Int(payload[3])
                height = Int(payload[4]) << 24 | Int(payload[5]) << 16 | Int(payload[6]) << 8 | Int(payload[7])
                guard Array(payload[8...]) == [8, 2, 0, 0, 0] else { throw Malformed(description: "format") }
            case "IDAT":
                compressed += payload
            case "IEND":
                sawEnd = true
            default:
                break
            }
            offset += 12 + length
        }
        guard sawEnd, offset == bytes.count else { throw Malformed(description: "no IEND") }

        // zlib with stored blocks only.
        guard compressed.count > 6, compressed[0] == 0x78 else { throw Malformed(description: "zlib header") }
        var position = 2
        var raw: [UInt8] = []
        var final = false
        while !final {
            guard position + 5 <= compressed.count else { throw Malformed(description: "deflate block") }
            final = compressed[position] & 1 == 1
            guard compressed[position] >> 1 == 0 else { throw Malformed(description: "not a stored block") }
            let count = Int(compressed[position + 1]) | Int(compressed[position + 2]) << 8
            let inverse = Int(compressed[position + 3]) | Int(compressed[position + 4]) << 8
            guard count == (~inverse & 0xFFFF) else { throw Malformed(description: "block length") }
            position += 5
            guard position + count <= compressed.count else { throw Malformed(description: "block data") }
            raw += compressed[position..<(position + count)]
            position += count
        }
        guard position + 4 == compressed.count else { throw Malformed(description: "trailing data") }
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in raw {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        let adler = UInt32(compressed[position]) << 24 | UInt32(compressed[position + 1]) << 16
            | UInt32(compressed[position + 2]) << 8 | UInt32(compressed[position + 3])
        guard adler == (b << 16 | a) else { throw Malformed(description: "Adler-32") }

        let stride = width * 3 + 1
        guard raw.count == stride * height else { throw Malformed(description: "pixel data size") }
        for row in 0..<height {
            guard raw[row * stride] == 0 else { throw Malformed(description: "filter type") }
            rgb += raw[(row * stride + 1)..<((row + 1) * stride)]
        }
    }

    /// Independent bitwise CRC-32, so the encoder's table is checked too.
    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }
}
