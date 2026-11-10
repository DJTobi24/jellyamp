import Foundation

/// Maps FFT bins onto log-spaced display bands and scales them to 0…1.
///
/// The FFT itself runs in the app shell (Accelerate); everything about how
/// the visualizer *looks* — band layout, dB scaling, tilt — lives here.
public struct SpectrumBands: Equatable, Sendable {
    /// FFT bin range feeding each band; every band has at least one bin.
    public let binRanges: [Range<Int>]
    /// Centre frequency of each band in Hz.
    public let centerFrequencies: [Double]
    /// Level mapped to 0 (anything quieter is invisible).
    public var floorDB: Float
    /// Level mapped to 1.
    public var ceilingDB: Float
    /// Boost per octave above 1 kHz. Music energy falls with frequency; a
    /// gentle tilt keeps the treble bands from looking dead.
    public var tiltDBPerOctave: Float

    /// - Parameters:
    ///   - binCount: number of usable FFT bins (fftSize / 2)
    ///   - sampleRate: sample rate of the analysed signal
    public init(
        bandCount: Int,
        binCount: Int,
        sampleRate: Double,
        minFrequency: Double = 40,
        maxFrequency: Double = 16_000,
        floorDB: Float = -66,
        ceilingDB: Float = -12,
        tiltDBPerOctave: Float = 3
    ) {
        self.floorDB = floorDB
        self.ceilingDB = ceilingDB
        self.tiltDBPerOctave = tiltDBPerOctave
        guard bandCount > 0, binCount > 1, sampleRate > 0 else {
            binRanges = []
            centerFrequencies = []
            return
        }
        let nyquist = sampleRate / 2
        let binWidth = nyquist / Double(binCount)
        let low = max(minFrequency, binWidth)
        let high = max(low * 2, min(maxFrequency, nyquist))
        let ratio = high / low
        var ranges: [Range<Int>] = []
        var centers: [Double] = []
        var previousEnd = 1   // bin 0 is DC
        for band in 0..<bandCount {
            let startFrequency = low * pow(ratio, Double(band) / Double(bandCount))
            let endFrequency = low * pow(ratio, Double(band + 1) / Double(bandCount))
            var start = max(previousEnd, Int(startFrequency / binWidth))
            start = min(start, binCount - 1)
            var end = max(start + 1, Int((endFrequency / binWidth).rounded(.up)))
            end = min(end, binCount)
            ranges.append(start..<end)
            centers.append((startFrequency * endFrequency).squareRoot())
            previousEnd = end
        }
        binRanges = ranges
        centerFrequencies = centers
    }

    public var bandCount: Int { binRanges.count }

    /// - Parameter power: squared magnitude per FFT bin, normalised so a
    ///   full-scale sine is 1.0 (0 dB).
    /// - Returns: one level in 0…1 per band.
    public func levels(fromPower power: [Float]) -> [Float] {
        var result = [Float](repeating: 0, count: binRanges.count)
        let span = ceilingDB - floorDB
        guard span > 0 else { return result }
        for (band, range) in binRanges.enumerated() {
            var peak: Float = 0
            for bin in range where bin < power.count {
                peak = max(peak, power[bin])
            }
            guard peak > 0 else { continue }
            let octavesAbove1k = Float(log2(centerFrequencies[band] / 1000))
            let db = 10 * log10(peak) + tiltDBPerOctave * octavesAbove1k
            result[band] = min(1, max(0, (db - floorDB) / span))
        }
        return result
    }
}

/// Frame-to-frame smoothing for the visualizer: fast attack, gravity-like
/// decay, and peak-hold caps that linger before falling.
public struct SpectrumSmoother: Equatable, Sendable {
    /// Time constant of the rise towards a louder target (seconds).
    public var attackTime: TimeInterval
    /// How fast a bar falls, in full-scale units per second.
    public var decayPerSecond: Float
    /// How long a peak cap stays put before it starts to fall.
    public var peakHoldTime: TimeInterval
    public var peakFallPerSecond: Float

    public private(set) var levels: [Float] = []
    public private(set) var peaks: [Float] = []
    private var peakAges: [TimeInterval] = []

    public init(
        attackTime: TimeInterval = 0.03,
        decayPerSecond: Float = 1.8,
        peakHoldTime: TimeInterval = 0.45,
        peakFallPerSecond: Float = 0.7
    ) {
        self.attackTime = attackTime
        self.decayPerSecond = decayPerSecond
        self.peakHoldTime = peakHoldTime
        self.peakFallPerSecond = peakFallPerSecond
    }

    /// True when every bar and cap has settled at zero (nothing to draw).
    public var isAtRest: Bool {
        !levels.contains { $0 > 0.001 } && !peaks.contains { $0 > 0.001 }
    }

    public mutating func reset() {
        levels = []
        peaks = []
        peakAges = []
    }

    /// Advances the animation by `dt` seconds towards `target` (0…1 per band).
    public mutating func update(target: [Float], dt: TimeInterval) {
        if levels.count != target.count {
            levels = [Float](repeating: 0, count: target.count)
            peaks = levels
            peakAges = [TimeInterval](repeating: 0, count: target.count)
        }
        // A stalled render loop (app resumed) must not produce a huge step.
        let step = min(max(dt, 0), 0.25)
        let rise = attackTime > 0 ? Float(1 - exp(-step / attackTime)) : 1
        for index in target.indices {
            let goal = min(1, max(0, target[index]))
            var level = levels[index]
            if goal > level {
                level += (goal - level) * rise
            } else {
                level = max(goal, level - decayPerSecond * Float(step))
            }
            levels[index] = level
            if level >= peaks[index] {
                peaks[index] = level
                peakAges[index] = 0
            } else {
                peakAges[index] += step
                if peakAges[index] > peakHoldTime {
                    peaks[index] = max(level, peaks[index] - peakFallPerSecond * Float(step))
                }
            }
        }
    }
}

/// Reduces a block of time-domain samples to a fixed number of points for the
/// "wave" visualizer style.
public enum WaveformReducer {
    /// Each output point is the sample with the largest magnitude in its
    /// slice (sign kept), so transients survive the reduction.
    public static func reduce(_ samples: [Float], points: Int) -> [Float] {
        guard points > 0 else { return [] }
        guard !samples.isEmpty else { return [Float](repeating: 0, count: points) }
        var result = [Float](repeating: 0, count: points)
        for point in 0..<points {
            let start = point * samples.count / points
            let end = max(start + 1, (point + 1) * samples.count / points)
            var extreme: Float = 0
            for index in start..<min(end, samples.count) where abs(samples[index]) > abs(extreme) {
                extreme = samples[index]
            }
            result[point] = min(1, max(-1, extreme))
        }
        return result
    }
}
