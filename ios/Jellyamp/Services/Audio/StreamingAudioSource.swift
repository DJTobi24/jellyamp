import Foundation
import AVFoundation
import AudioToolbox
import OSLog

/// True progressive streaming decoder. Pulls bytes (over HTTP, or from a local
/// file), parses them with **AudioFileStream**, decodes compressed packets to
/// PCM with **AudioConverter**, and schedules the PCM onto an
/// `AVAudioPlayerNode` — so playback starts after only a small prefix is
/// fetched, without downloading the whole track, while still feeding the
/// AVAudioEngine mixer (so crossfade keeps working).
///
/// `@unchecked Sendable`: mutable state is confined to `queue`; `format` and
/// `duration` are immutable once `make` returns.
final class StreamingAudioSource: NSObject, @unchecked Sendable {
    private(set) var format: AVAudioFormat!
    let duration: TimeInterval

    private let url: URL
    private let startTime: TimeInterval
    private let queue = DispatchQueue(label: "dev.djtobi.Jellyamp.afs")
    private let log = Logger(subsystem: "dev.djtobi.Jellyamp", category: "Streaming")

    private var streamID: AudioFileStreamID?
    private var converter: AudioConverterRef?
    private var sourceASBD = AudioStreamBasicDescription()
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var fileHandle: FileHandle?

    // Parsed-but-not-yet-decoded compressed packets.
    private struct Packet { let data: Data; let desc: AudioStreamPacketDescription }
    private var packets: [Packet] = []
    // The current input packet's bytes + description must stay valid for the
    // whole AudioConverterFillComplexBuffer call (i.e. after provideInput
    // returns), so they live in persistent buffers, replaced per packet.
    private var inputBytesPtr: UnsafeMutableRawPointer?
    private let inputDescPtr = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)

    private weak var node: AVAudioPlayerNode?
    private var onEnd: (() -> Void)?
    private var isRunning = false
    private var networkDone = false
    private var pendingFrames: AVAudioFrameCount = 0
    private var targetFrames: AVAudioFrameCount = 0

    private var formatContinuation: CheckedContinuation<Bool, Never>?
    private var resolvedFormat = false

    private init(url: URL, startTime: TimeInterval, duration: TimeInterval) {
        self.url = url
        self.startTime = startTime
        self.duration = duration
        super.init()
    }

    /// Opens the stream and waits until the audio format is known (header
    /// parsed). Returns nil if no decodable audio appears.
    static func make(url: URL, startTime: TimeInterval, duration: TimeInterval) async -> StreamingAudioSource? {
        let source = StreamingAudioSource(url: url, startTime: startTime, duration: duration)
        let ready = await source.open()
        return ready ? source : nil
    }

    private func open() async -> Bool {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioFileStreamOpen(context, propertyCallback, packetsCallback, 0, &streamID)
        guard status == noErr, streamID != nil else { return false }
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(returning: false); return }
                self.formatContinuation = continuation
                self.startFetching()
            }
        }
    }

    // MARK: - Fetching bytes

    private func startFetching() {
        if url.isFileURL {
            fileHandle = try? FileHandle(forReadingFrom: url)
            if startTime > 0, duration > 0, let size = fileSize() {
                try? fileHandle?.seek(toOffset: UInt64(Double(size) * (startTime / duration)))
            }
            readFileChunk()
        } else {
            var request = URLRequest(url: url)
            if startTime > 0, duration > 0 {
                // Approximate byte seek; AudioFileStream re-syncs to frame boundaries.
                if let size = remoteSize() {
                    let offset = Int64(Double(size) * (startTime / duration))
                    request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
                }
            }
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.dataTask(with: request)
            dataTask = task
            task.resume()
        }
    }

    private func readFileChunk() {
        queue.async { [weak self] in
            guard let self, let handle = self.fileHandle else { return }
            let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
            if data.isEmpty {
                self.networkDone = true
                self.finishIfDrained()
                return
            }
            self.parse(data)
            // Keep reading ahead a little, but let scheduling pace us.
            if self.pendingFrames < self.targetFrames || self.targetFrames == 0 {
                self.readFileChunk()
            }
        }
    }

    private func fileSize() -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
    }

    /// Best-effort content length via a HEAD request (synchronous, off the
    /// main thread inside `open`).
    private func remoteSize() -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let semaphore = DispatchSemaphore(value: 0)
        var length: Int64?
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.expectedContentLength > 0 {
                length = http.expectedContentLength
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 5)
        return length
    }

    // MARK: - Parsing / format

    private func parse(_ data: Data) {
        guard let streamID else { return }
        data.withUnsafeBytes { raw in
            _ = AudioFileStreamParseBytes(streamID, UInt32(data.count), raw.baseAddress, [])
        }
    }

    fileprivate func handleProperty(_ propertyID: AudioFileStreamPropertyID) {
        guard let streamID else { return }
        if propertyID == kAudioFileStreamProperty_ReadyToProducePackets {
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            AudioFileStreamGetProperty(streamID, kAudioFileStreamProperty_DataFormat, &size, &sourceASBD)
            setupConverter()
        }
    }

    private func setupConverter() {
        guard converter == nil, sourceASBD.mSampleRate > 0 else { return }
        let sampleRate = sourceASBD.mSampleRate
        let channels = max(1, AVAudioChannelCount(sourceASBD.mChannelsPerFrame))
        guard let destFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                             channels: channels, interleaved: false) else { return }
        var destASBD = destFormat.streamDescription.pointee
        var newConverter: AudioConverterRef?
        guard AudioConverterNew(&sourceASBD, &destASBD, &newConverter) == noErr, let newConverter else { return }
        converter = newConverter
        format = destFormat
        targetFrames = AVAudioFrameCount(sampleRate * 3)
        resolvedFormat = true
        formatContinuation?.resume(returning: true)
        formatContinuation = nil
    }

    fileprivate func handlePackets(count: UInt32, bytes: UnsafeRawPointer, descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
        guard let descriptions else { return }   // CBR-without-descriptions not handled (mp3/aac give descriptions)
        for i in 0..<Int(count) {
            let desc = descriptions[i]
            let data = Data(bytes: bytes.advanced(by: Int(desc.mStartOffset)), count: Int(desc.mDataByteSize))
            packets.append(Packet(data: data, desc: desc))
        }
        decodeAndSchedule()
    }

    // MARK: - Decode + schedule

    private func decodeAndSchedule() {
        guard isRunning, resolvedFormat, let converter, let node, let format else { return }
        while pendingFrames < targetFrames, !packets.isEmpty {
            let framesPerBuffer: AVAudioFrameCount = 8192
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerBuffer) else { return }
            var packetCount = framesPerBuffer   // PCM: 1 frame per packet
            let context = Unmanaged.passUnretained(self).toOpaque()
            let status = AudioConverterFillComplexBuffer(converter, converterInputCallback, context,
                                                         &packetCount, buffer.mutableAudioBufferList, nil)
            if packetCount == 0 { return }      // ran out of input for now (need more bytes)
            buffer.frameLength = packetCount
            let frames = buffer.frameLength
            pendingFrames += frames
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.queue.async {
                    guard let self else { return }
                    self.pendingFrames = self.pendingFrames > frames ? self.pendingFrames - frames : 0
                    self.decodeAndSchedule()
                    self.finishIfDrained()
                    if self.url.isFileURL, self.pendingFrames < self.targetFrames { self.readFileChunk() }
                }
            }
            if status != noErr && packetCount == 0 { return }
        }
    }

    /// Supplies one compressed packet to the converter. Must keep the packet's
    /// bytes alive until the converter is done with this call.
    fileprivate func provideInput(packetCount: UnsafeMutablePointer<UInt32>,
                                  data: UnsafeMutablePointer<AudioBufferList>,
                                  packetDescriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?) -> OSStatus {
        guard !packets.isEmpty else {
            packetCount.pointee = 0
            return kInputNeedsMoreData
        }
        let packet = packets.removeFirst()
        let count = packet.data.count
        inputBytesPtr?.deallocate()
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 1)
        packet.data.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: count)
        inputBytesPtr = bytes
        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers.mNumberChannels = sourceASBD.mChannelsPerFrame
        data.pointee.mBuffers.mDataByteSize = UInt32(count)
        data.pointee.mBuffers.mData = bytes
        inputDescPtr.pointee = AudioStreamPacketDescription(mStartOffset: 0,
                                                            mVariableFramesInPacket: packet.desc.mVariableFramesInPacket,
                                                            mDataByteSize: UInt32(count))
        packetDescriptions?.pointee = inputDescPtr
        packetCount.pointee = 1
        return noErr
    }

    private func finishIfDrained() {
        guard networkDone, packets.isEmpty, pendingFrames == 0, isRunning else { return }
        isRunning = false
        let end = onEnd
        onEnd = nil
        end?()
    }

    // MARK: - Public control

    func beginScheduling(on node: AVAudioPlayerNode, onEnd: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.node = node
            self.onEnd = onEnd
            self.isRunning = true
            self.decodeAndSchedule()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.onEnd = nil
            self.dataTask?.cancel()
            self.session?.invalidateAndCancel()
            try? self.fileHandle?.close()
            self.fileHandle = nil
            self.packets.removeAll()
            self.inputBytesPtr?.deallocate()
            self.inputBytesPtr = nil
            if let converter = self.converter { AudioConverterDispose(converter); self.converter = nil }
            if let streamID = self.streamID { AudioFileStreamClose(streamID); self.streamID = nil }
        }
    }

    deinit {
        inputBytesPtr?.deallocate()
        inputDescPtr.deallocate()
        if let converter { AudioConverterDispose(converter) }
        if let streamID { AudioFileStreamClose(streamID) }
    }
}

// MARK: - URLSession (remote byte delivery)

extension StreamingAudioSource: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async { [weak self] in
            guard let self, self.isRunning || !self.resolvedFormat else { return }
            self.parse(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async { [weak self] in
            guard let self else { return }
            if let error, !self.resolvedFormat {
                self.log.error("stream fetch failed: \(error.localizedDescription, privacy: .public)")
                self.formatContinuation?.resume(returning: false)
                self.formatContinuation = nil
            }
            self.networkDone = true
            self.finishIfDrained()
        }
    }
}

/// Custom OSStatus the converter input callback returns when it has no packets
/// buffered yet (more bytes still arriving).
private let kInputNeedsMoreData: OSStatus = -1

// MARK: - C callbacks (trampoline via the client-data context)

private func propertyCallback(_ clientData: UnsafeMutableRawPointer,
                              _ streamID: AudioFileStreamID,
                              _ propertyID: AudioFileStreamPropertyID,
                              _ flags: UnsafeMutablePointer<AudioFileStreamPropertyFlags>) {
    Unmanaged<StreamingAudioSource>.fromOpaque(clientData).takeUnretainedValue()
        .handleProperty(propertyID)
}

private func packetsCallback(_ clientData: UnsafeMutableRawPointer,
                             _ numberBytes: UInt32,
                             _ numberPackets: UInt32,
                             _ inputData: UnsafeRawPointer,
                             _ packetDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?) {
    Unmanaged<StreamingAudioSource>.fromOpaque(clientData).takeUnretainedValue()
        .handlePackets(count: numberPackets, bytes: inputData, descriptions: packetDescriptions)
}

private func converterInputCallback(_ converter: AudioConverterRef,
                                    _ packetCount: UnsafeMutablePointer<UInt32>,
                                    _ data: UnsafeMutablePointer<AudioBufferList>,
                                    _ packetDescriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
                                    _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let context else { packetCount.pointee = 0; return kInputNeedsMoreData }
    return Unmanaged<StreamingAudioSource>.fromOpaque(context).takeUnretainedValue()
        .provideInput(packetCount: packetCount, data: data, packetDescriptions: packetDescriptions)
}
