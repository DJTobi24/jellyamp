import Foundation
import AVFAudio
import JellyampCore

/// One playback chain: AVAudioPlayerNode → 10-band AVAudioUnitEQ → main mixer.
/// `EnginePlayer` alternates two of these for gapless joins and crossfades.
final class TrackSchedulerNode {
    let player = AVAudioPlayerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 10)

    private weak var engine: AVAudioEngine?
    private var file: AVAudioFile?

    init(engine: AVAudioEngine) {
        self.engine = engine
    }

    func attach(to engine: AVAudioEngine) {
        engine.attach(player)
        engine.attach(eq)
        engine.connect(player, to: eq, format: nil)
        engine.connect(eq, to: engine.mainMixerNode, format: nil)
    }

    /// Schedules a complete local file. Streaming scheduling from a growing
    /// cache file (with GaplessPlan frame trimming) lands in Phase 1.
    func schedule(file url: URL, gain: Float, completion: @escaping () -> Void) throws {
        let audioFile = try AVAudioFile(forReading: url)
        file = audioFile
        player.volume = gain
        player.scheduleFile(audioFile, at: nil) {
            completion()
        }
    }

    func apply(preset: EQPreset) {
        for (index, band) in preset.bands.prefix(eq.bands.count).enumerated() {
            let eqBand = eq.bands[index]
            eqBand.filterType = .parametric
            eqBand.frequency = Float(band.frequency)
            eqBand.gain = Float(band.gainDB)
            eqBand.bandwidth = Float(band.bandwidth)
            eqBand.bypass = false
        }
    }

    func stop() {
        player.stop()
        file = nil
    }
}
