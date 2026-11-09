import Foundation
import Accelerate
import AVFoundation
import JellyampCore

/// What a visualizer needs from the playing engine. `AudioEnginePlayer`
/// implements it; views reach it with `container.player as? AudioSpectrumProviding`
/// so `PlayerEngine` (Core) stays free of app-shell types.
protocol AudioSpectrumProviding: AnyObject {
    /// Latest analysis frame; read from the render loop of the visualizer.
    var spectrum: SpectrumStore { get }
    /// Each visible visualizer retains the tap while it is drawing and
    /// releases it when it stops; the tap is installed only while retained.
    func retainSpectrum()
    func releaseSpectrum()
}

/// Thread-safe hand-off between the audio tap (writer) and the visualizer's
/// render loop (reader). Deliberately not an `ObservableObject`: publishing
/// 40 frames a second through SwiftUI would invalidate the whole player.
final class SpectrumStore: @unchecked Sendable {
    private let lock = NSLock()
    private var levels: [Float] = []
    private var waveform: [Float] = []
    private var updatedAt: TimeInterval = 0

    func publish(levels: [Float], waveform: [Float]) {
        lock.lock()
        self.levels = levels
        self.waveform = waveform
        updatedAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    /// The latest frame, or empty arrays when the tap has gone quiet (engine
    /// stopped, tap removed) so the bars fall instead of freezing.
    func snapshot(maxAge: TimeInterval = 0.3) -> (levels: [Float], waveform: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        guard ProcessInfo.processInfo.systemUptime - updatedAt <= maxAge else { return ([], []) }
        return (levels, waveform)
    }

    func clear() {
        lock.lock()
        levels = []
        waveform = []
        updatedAt = 0
        lock.unlock()
    }
}

/// Windowed FFT of the mixer output (Accelerate). Band layout and scaling are
/// `SpectrumBands` (Core); this class only turns PCM into per-bin power.
///
/// All work happens on the tap's callback thread; buffers are allocated once.
final class SpectrumAnalyzer: @unchecked Sendable {
    static let fftSize = 2048
    static let bandCount = 32
    static let waveformPoints = 96

    private let log2n = vDSP_Length(11)   // 2^11 = fftSize
    private let setup: FFTSetup?
    private let window: UnsafeMutablePointer<Float>
    private let mono: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imaginary: UnsafeMutablePointer<Float>
    private let power: UnsafeMutablePointer<Float>

    private var bands: SpectrumBands?
    private var bandsSampleRate: Double = 0
    private let store: SpectrumStore

    init(store: SpectrumStore) {
        self.store = store
        let size = Self.fftSize
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = UnsafeMutablePointer<Float>.allocate(capacity: size)
        mono = UnsafeMutablePointer<Float>.allocate(capacity: size)
        windowed = UnsafeMutablePointer<Float>.allocate(capacity: size)
        real = UnsafeMutablePointer<Float>.allocate(capacity: size / 2)
        imaginary = UnsafeMutablePointer<Float>.allocate(capacity: size / 2)
        power = UnsafeMutablePointer<Float>.allocate(capacity: size / 2)
        mono.initialize(repeating: 0, count: size)
        windowed.initialize(repeating: 0, count: size)
        real.initialize(repeating: 0, count: size / 2)
        imaginary.initialize(repeating: 0, count: size / 2)
        power.initialize(repeating: 0, count: size / 2)
        window.initialize(repeating: 0, count: size)
        vDSP_hann_window(window, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
        window.deallocate()
        mono.deallocate()
        windowed.deallocate()
        real.deallocate()
        imaginary.deallocate()
        power.deallocate()
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let setup, let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let sampleRate = buffer.format.sampleRate
        guard frames > 0, channelCount > 0, sampleRate > 0 else { return }

        let size = Self.fftSize
        let half = size / 2
        let count = min(frames, size)
        let offset = frames - count   // analyse the newest samples of the block

        // Mono mix-down, zero-padded when the block is shorter than the FFT.
        vDSP_vclr(mono, 1, vDSP_Length(size))
        for channel in 0..<channelCount {
            vDSP_vadd(mono, 1, channels[channel] + offset, 1, mono, 1, vDSP_Length(count))
        }
        var divisor = Float(channelCount)
        vDSP_vsdiv(mono, 1, &divisor, mono, 1, vDSP_Length(count))

        let waveform = WaveformReducer.reduce(
            Array(UnsafeBufferPointer(start: mono, count: count)),
            points: Self.waveformPoints
        )

        vDSP_vmul(mono, 1, window, 1, windowed, 1, vDSP_Length(size))
        var split = DSPSplitComplex(realp: real, imagp: imaginary)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: half) { interleaved in
            vDSP_ctoz(interleaved, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvmags(&split, 1, power, 1, vDSP_Length(half))
        // zrip scales by 2 and the Hann window halves the amplitude, so a
        // full-scale sine peaks at size/2; normalise its power to 1.0.
        var scale = 1 / Float(half * half)
        vDSP_vsmul(power, 1, &scale, power, 1, vDSP_Length(half))

        if bands == nil || bandsSampleRate != sampleRate {
            bands = SpectrumBands(bandCount: Self.bandCount, binCount: half, sampleRate: sampleRate)
            bandsSampleRate = sampleRate
        }
        guard let bands else { return }
        let levels = bands.levels(fromPower: Array(UnsafeBufferPointer(start: power, count: half)))
        store.publish(levels: levels, waveform: waveform)
    }
}

/// Owns the tap on the engine's main mixer. A tap only observes the mixer's
/// output — it is not part of the render path, so installing or removing it
/// does not disturb playback. Main thread only.
final class SpectrumTap {
    private let store: SpectrumStore
    private let analyzer: SpectrumAnalyzer
    private var installed = false

    init(store: SpectrumStore) {
        self.store = store
        self.analyzer = SpectrumAnalyzer(store: store)
    }

    var isInstalled: Bool { installed }

    func install(on mixer: AVAudioMixerNode) {
        guard !installed else { return }
        // Before the session is active the mixer can report a 0 Hz format,
        // and installing a tap on that raises an exception. The engine calls
        // again once it has started.
        let format = mixer.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        let analyzer = self.analyzer
        // format nil = "whatever the bus produces": never mismatches.
        mixer.installTap(onBus: 0, bufferSize: AVAudioFrameCount(SpectrumAnalyzer.fftSize), format: nil) { buffer, _ in
            analyzer.process(buffer)
        }
        installed = true
    }

    func remove(from mixer: AVAudioMixerNode) {
        guard installed else { return }
        mixer.removeTap(onBus: 0)
        installed = false
        store.clear()
    }
}
