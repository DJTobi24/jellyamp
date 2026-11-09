import Foundation

/// Pure-Swift MD5 (RFC 1321).
///
/// Last.fm signs every authenticated call with the MD5 of its parameters.
/// CryptoKit's `Insecure.MD5` does not exist on Linux, where this package is
/// built and tested, so one small implementation is used on every platform —
/// that keeps the signing path identical in tests and on device. MD5 is used
/// here only because the Last.fm protocol demands it, never for security.
public enum MD5 {
    /// Per-round left-rotation amounts.
    private static let shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    /// `floor(2^32 * abs(sin(i + 1)))`, spelled out so the result does not
    /// depend on the platform's floating-point `sin`.
    private static let constants: [UInt32] = [
        0xd76a_a478, 0xe8c7_b756, 0x2420_70db, 0xc1bd_ceee, 0xf57c_0faf, 0x4787_c62a, 0xa830_4613, 0xfd46_9501,
        0x6980_98d8, 0x8b44_f7af, 0xffff_5bb1, 0x895c_d7be, 0x6b90_1122, 0xfd98_7193, 0xa679_438e, 0x49b4_0821,
        0xf61e_2562, 0xc040_b340, 0x265e_5a51, 0xe9b6_c7aa, 0xd62f_105d, 0x0244_1453, 0xd8a1_e681, 0xe7d3_fbc8,
        0x21e1_cde6, 0xc337_07d6, 0xf4d5_0d87, 0x455a_14ed, 0xa9e3_e905, 0xfcef_a3f8, 0x676f_02d9, 0x8d2a_4c8a,
        0xfffa_3942, 0x8771_f681, 0x6d9d_6122, 0xfde5_380c, 0xa4be_ea44, 0x4bde_cfa9, 0xf6bb_4b60, 0xbebf_bc70,
        0x289b_7ec6, 0xeaa1_27fa, 0xd4ef_3085, 0x0488_1d05, 0xd9d4_d039, 0xe6db_99e5, 0x1fa2_7cf8, 0xc4ac_5665,
        0xf429_2244, 0x432a_ff97, 0xab94_23a7, 0xfc93_a039, 0x655b_59c3, 0x8f0c_cc92, 0xffef_f47d, 0x8584_5dd1,
        0x6fa8_7e4f, 0xfe2c_e6e0, 0xa301_4314, 0x4e08_11a1, 0xf753_7e82, 0xbd3a_f235, 0x2ad7_d2bb, 0xeb86_d391,
    ]

    /// The 16-byte digest of `bytes`.
    public static func digest<Bytes: Sequence>(_ bytes: Bytes) -> [UInt8] where Bytes.Element == UInt8 {
        var message = Array(bytes)
        let bitLength = UInt64(message.count) &* 8

        // Padding: a single 1 bit, zeros up to 56 mod 64, then the original
        // length in bits as a little-endian 64-bit integer.
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for shift in stride(from: 0, to: 64, by: 8) {
            message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }

        var a0: UInt32 = 0x6745_2301
        var b0: UInt32 = 0xefcd_ab89
        var c0: UInt32 = 0x98ba_dcfe
        var d0: UInt32 = 0x1032_5476

        var words = [UInt32](repeating: 0, count: 16)
        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let base = chunkStart + i * 4
                let byte0 = UInt32(message[base])
                let byte1 = UInt32(message[base + 1]) << 8
                let byte2 = UInt32(message[base + 2]) << 16
                let byte3 = UInt32(message[base + 3]) << 24
                words[i] = byte0 | byte1 | byte2 | byte3
            }

            var a = a0
            var b = b0
            var c = c0
            var d = d0

            for i in 0..<64 {
                var f: UInt32
                let g: Int
                switch i / 16 {
                case 0:
                    f = (b & c) | (~b & d)
                    g = i
                case 1:
                    f = (d & b) | (~d & c)
                    g = (5 * i + 1) % 16
                case 2:
                    f = b ^ c ^ d
                    g = (3 * i + 5) % 16
                default:
                    f = c ^ (b | ~d)
                    g = (7 * i) % 16
                }
                f = f &+ a &+ constants[i] &+ words[g]
                a = d
                d = c
                c = b
                let s = shifts[i]
                b = b &+ ((f << s) | (f >> (32 - s)))
            }

            a0 = a0 &+ a
            b0 = b0 &+ b
            c0 = c0 &+ c
            d0 = d0 &+ d
        }

        var output: [UInt8] = []
        output.reserveCapacity(16)
        for word in [a0, b0, c0, d0] {
            for shift in stride(from: 0, to: 32, by: 8) {
                output.append(UInt8(truncatingIfNeeded: word >> UInt32(shift)))
            }
        }
        return output
    }

    /// Lower-case hex digest of the UTF-8 bytes of `string` — the form
    /// Last.fm expects for `api_sig`.
    public static func hexDigest(of string: String) -> String {
        hexDigest(of: Array(string.utf8))
    }

    public static func hexDigest<Bytes: Sequence>(of bytes: Bytes) -> String where Bytes.Element == UInt8 {
        let hexDigits = Array("0123456789abcdef".utf8)
        var characters: [UInt8] = []
        characters.reserveCapacity(32)
        for byte in digest(bytes) {
            characters.append(hexDigits[Int(byte >> 4)])
            characters.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: characters, as: UTF8.self)
    }
}
