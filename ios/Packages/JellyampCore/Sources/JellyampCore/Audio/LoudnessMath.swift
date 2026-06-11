import Foundation

/// Converts loudness metadata (Jellyfin `NormalizationGain`, ReplayGain-style
/// dB values, or measured LUFS) into the linear gain applied per track.
public enum LoudnessMath {
    /// Reference loudness used when deriving gain from a measured LUFS value.
    public static let referenceLUFS: Double = -18.0

    public static func linearGain(fromDB db: Double) -> Double {
        pow(10.0, db / 20.0)
    }

    public static func db(fromLinearGain gain: Double) -> Double {
        20.0 * log10(gain)
    }

    /// Gain in dB needed to bring a track measured at `integratedLufs` to the
    /// reference loudness.
    public static func gainDB(integratedLufs: Double, reference: Double = referenceLUFS) -> Double {
        reference - integratedLufs
    }

    /// The per-track linear gain the engine applies.
    ///
    /// - Parameters:
    ///   - normalizationGainDB: dB gain from metadata (positive = boost). `nil` → unity.
    ///   - preampDB: user preamp on top of leveling.
    ///   - truePeakDB: track true peak in dBTP when known; the result is
    ///     clamped so peak + gain never exceeds 0 dBTP (clipping guard).
    public static func playbackGain(normalizationGainDB: Double?, preampDB: Double = 0, truePeakDB: Double? = nil) -> Double {
        let requestedDB = (normalizationGainDB ?? 0) + preampDB
        let allowedDB: Double
        if let peak = truePeakDB {
            allowedDB = min(requestedDB, -peak)
        } else {
            allowedDB = requestedDB
        }
        return linearGain(fromDB: allowedDB)
    }
}
