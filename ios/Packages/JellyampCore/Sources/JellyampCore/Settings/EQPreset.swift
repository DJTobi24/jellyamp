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

    /// Standard 10 ISO octave center frequencies, flat.
    public static var flat: EQPreset {
        EQPreset(
            id: "flat",
            name: "Flat",
            bands: [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000].map { Band(frequency: $0) }
        )
    }
}
