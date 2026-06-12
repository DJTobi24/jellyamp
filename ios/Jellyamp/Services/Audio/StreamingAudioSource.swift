import Foundation
import AVFoundation
import CoreMedia
import OSLog

/// Progressively decodes a remote (or local) audio file with `AVAssetReader`
/// and schedules PCM buffers onto an `AVAudioPlayerNode` — so playback starts
/// without downloading the whole file, while still feeding the AVAudioEngine
/// mixer (which is what makes a real crossfade possible).
///
/// `@unchecked Sendable`: mutable state is confined to `queue`; `format` and
/// `duration` are immutable after `make`.
final class StreamingAudioSource: @unchecked Sendable {
    let format: AVAudioFormat
    let duration: TimeInterval

    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private weak var node: AVAudioPlayerNode?
    private let queue = DispatchQueue(label: "dev.djtobi.Jellyamp.streamingSource")
    private var isRunning = false
    private var finishedReading = false
    private var pendingFrames: AVAudioFrameCount = 0
    private let targetFrames: AVAudioFrameCount
    private var onEnd: (() -> Void)?

    private init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, format: AVAudioFormat, duration: TimeInterval) {
        self.reader = reader
        self.output = output
        self.format = format
        self.duration = duration
        self.targetFrames = AVAudioFrameCount(format.sampleRate * 3)   // keep ~3 s buffered
    }

    /// Loads the asset, builds a float-PCM reader starting at `startTime`, and
    /// begins reading. Returns nil if there's no decodable audio track or the
    /// reader can't start (e.g. the URL isn't readable progressively).
    static func make(url: URL, startTime: TimeInterval) async -> StreamingAudioSource? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        guard let descriptions = try? await track.load(.formatDescriptions),
              let description = descriptions.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return nil }
        let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 44_100
        let channels = max(1, AVAudioChannelCount(asbd.mChannelsPerFrame))
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: channels, interleaved: false) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        if startTime > 0 {
            reader.timeRange = CMTimeRange(start: CMTime(seconds: startTime, preferredTimescale: 600),
                                           duration: .positiveInfinity)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        return StreamingAudioSource(reader: reader, output: output, format: format, duration: duration)
    }

    /// Starts scheduling decoded buffers onto `node` (connect it with `format`
    /// first). `onEnd` fires once everything scheduled has finished playing.
    func beginScheduling(on node: AVAudioPlayerNode, onEnd: @escaping () -> Void) {
        self.node = node
        self.onEnd = onEnd
        queue.async { [weak self] in
            self?.isRunning = true
            self?.fill()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.onEnd = nil
            if self.reader.status == .reading { self.reader.cancelReading() }
        }
    }

    /// Reads + schedules until ~`targetFrames` are buffered ahead. Must run on
    /// `queue`.
    private func fill() {
        guard isRunning, let node else { return }
        while pendingFrames < targetFrames {
            guard reader.status == .reading, let sample = output.copyNextSampleBuffer() else {
                finishedReading = true
                if pendingFrames == 0 { notifyEnd() }
                return
            }
            guard let buffer = makeBuffer(from: sample) else { continue }
            let frames = buffer.frameLength
            pendingFrames += frames
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.queue.async {
                    guard let self else { return }
                    self.pendingFrames = self.pendingFrames > frames ? self.pendingFrames - frames : 0
                    if self.finishedReading, self.pendingFrames == 0 { self.notifyEnd() }
                    else { self.fill() }
                }
            }
        }
    }

    private func notifyEnd() {
        guard isRunning else { return }
        isRunning = false
        let end = onEnd
        onEnd = nil
        end?()
    }

    private func makeBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
