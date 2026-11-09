import Foundation

/// A 10-band parametric EQ preset, applied to both player chains at once.
public struct EQPreset: Codable, Equatable, Identifiable, Sendable {
    public struct Band: Codable, Equatable, Sendable {
        public var frequency: Double
        public var gainDB: Double
        public var bandwidth: Double

        public init(frequency: Double, gainDB: Double = 0, bandwidth: Double = 1.0) {
            self.frequency = frequency
            self.gainDB = gainDB
            self.bandwidth = bandwidth
        }
    }

    public var id: String
    public var name: String
    public var bands: [Band]

    public init(id: String = UUID().uuidString, name: String, bands: [Band]) {
        self.id = id
        self.name = name
        self.bands = bands
    }

    /// Standard 10 ISO octave center frequencies.
    public static let frequencies: [Double] = [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    /// Standard 10 ISO octave center frequencies, flat.
    public static var flat: EQPreset {
        EQPreset(id: "flat", name: "Flat", bands: frequencies.map { Band(frequency: $0) })
    }

    private static func preset(_ id: String, _ name: String, _ gains: [Double]) -> EQPreset {
        EQPreset(id: id, name: name, bands: zip(frequencies, gains).map { Band(frequency: $0, gainDB: $1) })
    }

    /// Built-in presets offered in Settings. Gains are modest (±6 dB) so they
    /// shape the sound without clipping the engine.
    public static let builtIns: [EQPreset] = [
        .flat,
        preset("bass", "Bass Boost", [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        preset("treble", "Treble Boost", [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        preset("vocal", "Vocal", [-2, -1, 0, 1, 3, 4, 3, 1, 0, -1]),
        preset("rock", "Rock", [4, 3, 1, -1, -1, 0, 2, 3, 4, 4]),
        preset("electronic", "Electronic", [5, 4, 1, 0, -2, 1, 0, 1, 4, 5]),
        preset("acoustic", "Acoustic", [4, 3, 2, 0, 1, 1, 2, 3, 3, 2]),
        preset("hiphop", "Hip-Hop", [5, 4, 2, 3, -1, -1, 1, 1, 2, 3]),
        preset("loudness", "Loudness", [6, 4, 0, 0, -2, 0, 1, 3, 5, 6]),
    ]

    public static func builtIn(id: String?) -> EQPreset? {
        guard let id else { return nil }
        return builtIns.first { $0.id == id }
    }
}
