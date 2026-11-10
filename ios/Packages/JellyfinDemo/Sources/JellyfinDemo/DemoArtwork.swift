import Foundation

/// Cover art of the demo library, drawn in code: every album, artist and
/// playlist gets a gradient with a simple geometric motif in its own colours.
/// Rendered per pixel into an RGB bitmap and written as PNG (uncompressed
/// deflate blocks — the images travel over loopback, size does not matter),
/// so no image library and no bundled artwork is involved.
public enum DemoArtwork {
    struct Palette: Sendable, Equatable {
        var background: UInt32
        var accent: UInt32
        var highlight: UInt32

        init(_ background: UInt32, _ accent: UInt32, _ highlight: UInt32) {
            self.background = background
            self.accent = accent
            self.highlight = highlight
        }
    }

    enum Pattern: Sendable, Equatable {
        case rings, sun, stripes, dots, waves, mountains
        /// Artists: a two-tone disc.
        case portrait
        /// Playlists: four tiles.
        case mosaic
    }

    public static let minimumSize = 48
    public static let maximumSize = 640
    public static let defaultSize = 480

    /// PNG for a library item, or nil if the item has no generated cover.
    /// `size` is the edge length in pixels (clamped to a sane range).
    public static func png(forItemID itemID: String, size: Int) -> Data? {
        guard let (palette, pattern) = design(forItemID: itemID) else { return nil }
        let edge = min(max(size, minimumSize), maximumSize)
        return cache.value(for: "\(itemID)@\(edge)") {
            PNGEncoder.encode(rgb: render(palette: palette, pattern: pattern, size: edge, seed: DemoRandom.hash(itemID)), width: edge, height: edge)
        }
    }

    /// The image tag Jellyfin would report: changes when the image changes.
    static func tag(forItemID itemID: String) -> String {
        let hash = DemoRandom.hash("art:" + itemID)
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex + "0000000000000000"
    }

    static func design(forItemID itemID: String) -> (Palette, Pattern)? {
        if let album = DemoCatalog.albums.first(where: { $0.id == itemID }) {
            return (album.palette, album.pattern)
        }
        if let artist = DemoCatalog.artists.first(where: { $0.id == itemID }) {
            return (artist.palette, .portrait)
        }
        if itemID.hasPrefix("d") {
            // Playlists, including ones created at runtime: colours from the ID.
            // The trailing number rather than a hash: neighbouring playlists
            // then never share a palette.
            let number = Int(itemID.suffix(6)) ?? 0
            let palettes = DemoCatalog.albums.map(\.palette)
            return (palettes[(number * 5 + 2) % palettes.count], .mosaic)
        }
        return nil
    }

    private static let cache = DataCache(limit: 96)

    // MARK: - Rendering

    private struct RGB {
        var r: Double
        var g: Double
        var b: Double

        init(_ hex: UInt32) {
            r = Double((hex >> 16) & 0xFF) / 255
            g = Double((hex >> 8) & 0xFF) / 255
            b = Double(hex & 0xFF) / 255
        }

        init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        func mixed(with other: RGB, _ amount: Double) -> RGB {
            let t = min(max(amount, 0), 1)
            return RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
        }
    }

    /// 0 below `edge0`, 1 above `edge1`, smooth in between: the antialiasing
    /// of every shape edge.
    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func render(palette: Palette, pattern: Pattern, size: Int, seed: UInt64) -> [UInt8] {
        let background = RGB(palette.background)
        let accent = RGB(palette.accent)
        let highlight = RGB(palette.highlight)
        // One pixel in unit coordinates: the width of an antialiased edge.
        let px = 1.0 / Double(size)
        let jitterA = DemoRandom.unit(seed &+ 1)
        let jitterB = DemoRandom.unit(seed &+ 2)

        var pixels = [UInt8](repeating: 0, count: size * size * 3)
        pixels.withUnsafeMutableBufferPointer { buffer in
            for y in 0..<size {
                let v = (Double(y) + 0.5) * px
                for x in 0..<size {
                    let u = (Double(x) + 0.5) * px
                    // Diagonal gradient under every motif.
                    var color = background.mixed(with: accent, (u * 0.45 + v * 0.75) * 0.55)

                    switch pattern {
                    case .rings:
                        let cx = 0.3 + 0.4 * jitterA
                        let cy = 0.3 + 0.4 * jitterB
                        let distance = ((u - cx) * (u - cx) + (v - cy) * (v - cy)).squareRoot()
                        let wave = 0.5 + 0.5 * cos(distance * 46)
                        let ring = smoothstep(0.78, 0.86, wave) * max(0, 1 - distance * 1.1)
                        color = color.mixed(with: highlight, ring * 0.85)
                    case .sun:
                        let cx = 0.5
                        let cy = 0.44
                        let distance = ((u - cx) * (u - cx) + (v - cy) * (v - cy)).squareRoot()
                        let disc = 1 - smoothstep(0.26 - px, 0.26 + px, distance)
                        // Horizon bands cut through the lower half of the sun.
                        let band = 0.5 + 0.5 * sin((v - 0.44) * 95)
                        let cut = v > 0.44 ? smoothstep(0.35, 0.5, band) * smoothstep(0.44, 0.7, v) : 0
                        color = color.mixed(with: highlight, disc * (1 - cut))
                        let ground = smoothstep(0.74 - px, 0.74 + px, v)
                        color = color.mixed(with: background, ground * 0.75)
                        let grid = smoothstep(0.9, 0.97, 0.5 + 0.5 * cos((u - 0.5) / max(v - 0.7, 0.02) * 9))
                        color = color.mixed(with: accent, ground * grid * 0.6)
                    case .stripes:
                        let t = (u + v * (0.6 + 0.5 * jitterA)) * 7
                        let stripe = smoothstep(0.42, 0.5, abs(t - t.rounded()) )
                        let fade = smoothstep(0.1, 0.9, v)
                        color = color.mixed(with: highlight, (1 - stripe) * (0.25 + 0.6 * fade))
                    case .dots:
                        let cells = 6.0
                        let gx = u * cells
                        let gy = v * cells
                        let dx = gx - gx.rounded(.down) - 0.5
                        let dy = gy - gy.rounded(.down) - 0.5
                        let distance = (dx * dx + dy * dy).squareRoot()
                        let column = gx.rounded(.down)
                        let row = gy.rounded(.down)
                        let radius = 0.12 + 0.3 * DemoRandom.unit(seed &+ UInt64(column * 31 + row * 7 + 11))
                        let dot = 1 - smoothstep(radius - px * cells, radius + px * cells, distance)
                        color = color.mixed(with: highlight, dot * 0.9)
                    case .waves:
                        for band in 0..<4 {
                            let base = 0.34 + Double(band) * 0.16
                            let line = base + 0.045 * sin(u * (5.5 + Double(band) * 1.7) + jitterA * 6 + Double(band))
                            let below = smoothstep(line - px, line + px, v)
                            let tint = band % 2 == 0 ? highlight : accent
                            color = color.mixed(with: tint, below * 0.32)
                        }
                    case .mountains:
                        let moon = 1 - smoothstep(0.09 - px, 0.09 + px, ((u - 0.72) * (u - 0.72) + (v - 0.24) * (v - 0.24)).squareRoot())
                        color = color.mixed(with: highlight, moon * 0.95)
                        for layer in 0..<3 {
                            let peak = 0.22 + 0.28 * Double(layer) + 0.12 * jitterA
                            let height = 0.5 - Double(layer) * 0.07
                            let ridge = 1 - height + abs(u - peak) * (0.75 - Double(layer) * 0.12)
                                + 0.02 * sin(u * 40 + Double(layer) * 2)
                            let inside = smoothstep(ridge - px, ridge + px, v)
                            let tint = layer == 2 ? background : (layer == 1 ? accent : highlight)
                            color = color.mixed(with: tint, inside * (0.45 + 0.2 * Double(layer)))
                        }
                    case .portrait:
                        let distance = ((u - 0.5) * (u - 0.5) + (v - 0.5) * (v - 0.5)).squareRoot()
                        let disc = 1 - smoothstep(0.34 - px, 0.34 + px, distance)
                        color = color.mixed(with: highlight, disc * 0.92)
                        let ox = 0.5 + 0.14 * (jitterA - 0.5) * 2
                        let oy = 0.5 + 0.14 * (jitterB - 0.5) * 2
                        let inner = ((u - ox) * (u - ox) + (v - oy) * (v - oy)).squareRoot()
                        let shade = 1 - smoothstep(0.2 - px, 0.2 + px, inner)
                        color = color.mixed(with: accent, shade * disc)
                    case .mosaic:
                        let column = u < 0.5 ? 0 : 1
                        let row = v < 0.5 ? 0 : 1
                        let tile = column + row * 2
                        let tints = [accent, highlight, background.mixed(with: highlight, 0.35), accent.mixed(with: background, 0.45)]
                        color = tints[(tile + Int(seed % 4)) % 4]
                        let cx = 0.25 + 0.5 * Double(column)
                        let cy = 0.25 + 0.5 * Double(row)
                        let distance = ((u - cx) * (u - cx) + (v - cy) * (v - cy)).squareRoot()
                        let radius = 0.07 + 0.09 * DemoRandom.unit(seed &+ UInt64(tile) &+ 5)
                        let dot = 1 - smoothstep(radius - px, radius + px, distance)
                        color = color.mixed(with: background, dot * 0.85)
                    }

                    // Slight vignette so covers do not look flat.
                    let edge = ((u - 0.5) * (u - 0.5) + (v - 0.5) * (v - 0.5)) * 0.5
                    let offset = (y * size + x) * 3
                    buffer[offset] = UInt8(min(max(color.r * (1 - edge), 0), 1) * 255)
                    buffer[offset + 1] = UInt8(min(max(color.g * (1 - edge), 0), 1) * 255)
                    buffer[offset + 2] = UInt8(min(max(color.b * (1 - edge), 0), 1) * 255)
                }
            }
        }
        return pixels
    }
}

/// Minimal PNG writer: 8-bit RGB, no filtering, stored (uncompressed) deflate.
enum PNGEncoder {
    static func encode(rgb: [UInt8], width: Int, height: Int) -> Data {
        precondition(rgb.count == width * height * 3)
        // Scanlines, each led by filter type 0.
        var raw = [UInt8]()
        raw.reserveCapacity(height * (width * 3 + 1))
        for row in 0..<height {
            raw.append(0)
            raw.append(contentsOf: rgb[(row * width * 3)..<((row + 1) * width * 3)])
        }

        var zlib = [UInt8]()
        zlib.reserveCapacity(raw.count + raw.count / 65_535 * 5 + 16)
        zlib.append(0x78)
        zlib.append(0x01)
        var offset = 0
        repeat {
            let count = min(65_535, raw.count - offset)
            let isLast = offset + count >= raw.count
            zlib.append(isLast ? 1 : 0)
            zlib.append(UInt8(count & 0xFF))
            zlib.append(UInt8(count >> 8))
            zlib.append(UInt8(~count & 0xFF))
            zlib.append(UInt8((~count >> 8) & 0xFF))
            zlib.append(contentsOf: raw[offset..<(offset + count)])
            offset += count
        } while offset < raw.count
        appendBigEndian(adler32(raw), to: &zlib)

        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        var header = [UInt8]()
        appendBigEndian(UInt32(width), to: &header)
        appendBigEndian(UInt32(height), to: &header)
        header.append(contentsOf: [8, 2, 0, 0, 0])   // 8 bit, truecolour, deflate, no filter method, no interlace
        appendChunk("IHDR", header, to: &png)
        appendChunk("IDAT", zlib, to: &png)
        appendChunk("IEND", [], to: &png)
        return Data(png)
    }

    private static func appendChunk(_ type: String, _ payload: [UInt8], to png: inout [UInt8]) {
        appendBigEndian(UInt32(payload.count), to: &png)
        let typeBytes = Array(type.utf8)
        png.append(contentsOf: typeBytes)
        png.append(contentsOf: payload)
        var crc = crc32(typeBytes, seed: 0xFFFF_FFFF)
        crc = crc32(payload, seed: crc)
        appendBigEndian(crc ^ 0xFFFF_FFFF, to: &png)
    }

    private static func appendBigEndian(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8((value >> 24) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    /// Running CRC-32 (without the final inversion).
    private static func crc32(_ bytes: [UInt8], seed: UInt32) -> UInt32 {
        var crc = seed
        let table = crcTable
        bytes.withUnsafeBufferPointer { buffer in
            table.withUnsafeBufferPointer { lookup in
                for byte in buffer {
                    crc = lookup[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
                }
            }
        }
        return crc
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        bytes.withUnsafeBufferPointer { buffer in
            var index = 0
            while index < buffer.count {
                // 5552 bytes is the most that cannot overflow 32 bits.
                let end = min(index + 5552, buffer.count)
                while index < end {
                    a &+= UInt32(buffer[index])
                    b &+= a
                    index += 1
                }
                a %= 65_521
                b %= 65_521
            }
        }
        return (b << 16) | a
    }
}
