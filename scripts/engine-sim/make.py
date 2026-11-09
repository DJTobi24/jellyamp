"""Generates a Linux *behavioural* harness for AudioEnginePlayer.

The app target cannot be built or run off macOS, but the player's control
flow — queue handling, seek, crossfade, failures, sleep timer, engine
recovery, playback reporting — is plain Swift around a handful of
AVFoundation calls. This script writes a throw-away SwiftPM package in which

- the real AudioEnginePlayer.swift, PlaybackSupport.swift and
  PlayerStateModel.swift are compiled unchanged (only the two Objective-C
  selector registrations are rewritten; Linux has no ObjC runtime),
- AVFoundation / AudioToolbox / OSLog / Network / Combine are tiny stub
  modules: player nodes whose clocks advance in real time, an engine that
  can be "stopped by the system",
- StreamingAudioSource is a fake that "plays" for the track's duration,
  can be told to fail or to load slowly, and records what was opened,

and main.swift drives scenarios against it. With JELLYFIN_TEST_URL set the
playback reports go to a real server and play counts are checked.

It proves the state machine, not the sound: decoding, scheduling and the
audible result still need a device. See run.sh.

usage: make.py <repo root> <output dir>
"""
import os
import re
import sys

worktree, out = sys.argv[1], sys.argv[2]

files = {}
files["Package.swift"] = '''// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShellSim",
    dependencies: [
        .package(path: "__ROOT__/ios/Packages/JellyampCore"),
        .package(path: "__ROOT__/ios/Packages/JellyfinBackend"),
    ],
    targets: [
        .target(name: "AVFoundation", dependencies: ["Combine"]),
        .target(name: "AudioToolbox"),
        .target(name: "OSLog"),
        .target(name: "Network"),
        .target(name: "Combine"),
        .executableTarget(
            name: "Sim",
            dependencies: ["AVFoundation", "AudioToolbox", "OSLog", "Network", "Combine",
                           .product(name: "JellyampCore", package: "JellyampCore"),
                           .product(name: "JellyfinBackend", package: "JellyfinBackend")],
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        ),
    ]
)
'''
files["Sources/Combine/Combine.swift"] = '''public protocol ObservableObject: AnyObject {}

@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
'''
files["Sources/OSLog/OSLog.swift"] = '''import Foundation

public struct OSLogPrivacy { public static let `public` = OSLogPrivacy() }

public struct OSLogMessage: ExpressibleByStringInterpolation {
    public var text = ""
    public struct StringInterpolation: StringInterpolationProtocol {
        var text = ""
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) { text += literal }
        public mutating func appendInterpolation<T>(_ value: @autoclosure @escaping () -> T, privacy: OSLogPrivacy = .public) {
            text += "\\(value())"
        }
    }
    public init(stringLiteral value: String) { text = value }
    public init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }
}

public struct Logger: Sendable {
    public static let verbose = ProcessInfo.processInfo.environment["SIM_VERBOSE"] != nil
    let category: String
    public init(subsystem: String, category: String) { self.category = category }
    public func info(_ message: OSLogMessage) { if Self.verbose { print("      [\\(category)] \\(message.text)") } }
    public func error(_ message: OSLogMessage) { if Self.verbose { print("      [\\(category)] ERROR \\(message.text)") } }
}
'''
files["Sources/Network/Network.swift"] = '''import Foundation

public struct NWPath {
    public enum Status { case satisfied, unsatisfied, requiresConnection }
    public var status: Status = .satisfied
    public var isExpensive = false
    public func usesInterfaceType(_ type: NWInterface.InterfaceType) -> Bool { false }
}
public enum NWInterface { public enum InterfaceType { case wifi, cellular, wiredEthernet, loopback, other } }
public final class NWPathMonitor {
    public init() {}
    public var pathUpdateHandler: (@Sendable (NWPath) -> Void)?
    public func start(queue: DispatchQueue) {}
}
'''
files["Sources/AudioToolbox/AudioToolbox.swift"] = '''public typealias AudioFileTypeID = UInt32
public let kAudioFileMP3Type: AudioFileTypeID = 1
public let kAudioFileAAC_ADTSType: AudioFileTypeID = 2
public let kAudioFileM4AType: AudioFileTypeID = 3
public let kAudioFileFLACType: AudioFileTypeID = 4
public let kAudioFileWAVEType: AudioFileTypeID = 5
public let kAudioFileAIFFType: AudioFileTypeID = 6
'''
files["Sources/AVFoundation/AVFoundation.swift"] = '''@_exported import Foundation
@_exported import Combine

open class AVAudioNode: NSObject {
    public func installTap(onBus bus: Int, bufferSize: UInt32, format: AVAudioFormat?, block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) {}
    public func removeTap(onBus bus: Int) {}
    public func outputFormat(forBus bus: Int) -> AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)! }
    public var lastRenderTime: AVAudioTime? { AVAudioTime() }
}
public final class AVAudioPCMBuffer {}
public final class AVAudioTime {
    public var sampleTime: Int64 = 0
    public var sampleRate: Double = 0
    public init(sampleTime: Int64 = 0, sampleRate: Double = 0) { self.sampleTime = sampleTime; self.sampleRate = sampleRate }
}
public final class AVAudioFormat {
    public init?(standardFormatWithSampleRate sampleRate: Double, channels: UInt32) {}
    public var sampleRate: Double { 44_100 }
    public var channelCount: UInt32 { 2 }
}
public final class AVAudioMixerNode: AVAudioNode { public var outputVolume: Float = 1 }

/// A player node whose clock advances in real time while it is "playing".
/// Like the real one: no player time while paused/stopped, stop() resets the
/// timeline and drops what was scheduled.
public final class AVAudioPlayerNode: AVAudioNode {
    public override init() {}
    public private(set) var isPlaying = false
    private var accumulated: TimeInterval = 0
    private var resumedAt: Date?
    /// Bumped by stop(): whatever was scheduled before is gone.
    public private(set) var scheduleEpoch = 0
    public var volume: Float = 1

    public func play() {
        guard !isPlaying else { return }
        isPlaying = true
        resumedAt = Date()
    }
    public func pause() {
        guard isPlaying, let resumedAt else { return }
        accumulated += Date().timeIntervalSince(resumedAt)
        isPlaying = false
        self.resumedAt = nil
    }
    public func stop() {
        isPlaying = false
        accumulated = 0
        resumedAt = nil
        scheduleEpoch += 1
    }
    public var playedSeconds: TimeInterval {
        accumulated + (resumedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }
    public func playerTime(forNodeTime nodeTime: AVAudioTime) -> AVAudioTime? {
        guard isPlaying else { return nil }
        return AVAudioTime(sampleTime: Int64(playedSeconds * 44_100), sampleRate: 44_100)
    }
}
public final class AVAudioUnitEQ: AVAudioNode {
    public init(numberOfBands: Int) {}
    public var globalGain: Float = 0
}
public final class AVAudioEngine: NSObject {
    public static weak var last: AVAudioEngine?
    public override init() { super.init(); AVAudioEngine.last = self }
    public let mainMixerNode = AVAudioMixerNode()
    public private(set) var nodes: [AVAudioNode] = []
    public private(set) var startCount = 0
    public func attach(_ node: AVAudioNode) { nodes.append(node) }
    public func connect(_ node1: AVAudioNode, to node2: AVAudioNode, format: AVAudioFormat?) {}
    public func prepare() {}
    public func start() throws { isRunning = true; startCount += 1 }
    public func stop() { halt() }
    public private(set) var isRunning = false
    public var playerNodes: [AVAudioPlayerNode] { nodes.compactMap { $0 as? AVAudioPlayerNode } }

    private func halt() {
        isRunning = false
        // Worst case for the player: everything scheduled is lost.
        playerNodes.forEach { $0.stop() }
    }
    /// What iOS does on a route / hardware format change.
    public func simulateConfigurationChange() {
        halt()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: self)
    }
    /// What iOS does when a phone call interrupts.
    public func simulateInterruption() { halt() }
}
public final class AVAudioSession {
    public struct Category { public static let playback = Category() }
    public struct Mode { public static let `default` = Mode() }
    public static func sharedInstance() -> AVAudioSession { AVAudioSession() }
    public func setActive(_ active: Bool) throws {}
    public func setCategory(_ category: Category, mode: Mode) throws {}
    public static let mediaServicesWereResetNotification = Notification.Name("reset")
}
public extension Notification.Name {
    static let AVAudioEngineConfigurationChange = Notification.Name("config")
}
'''
files["Sources/Sim/Stubs.swift"] = '''import Foundation
import AVFoundation
import AudioToolbox
import JellyampCore
import JellyfinBackend

extension String {
    /// Foundation on Linux has no String(localized:).
    init(localized key: String) { self = key }
}

/// Knobs the scenarios turn.
final class SimWorld: @unchecked Sendable {
    static let shared = SimWorld()
    private let lock = NSLock()
    private var _failing: Set<String> = []
    private var _loadDelay: TimeInterval = 0
    private var _opened: [String] = []
    var failing: Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return _failing }
        set { lock.lock(); _failing = newValue; lock.unlock() }
    }
    var loadDelay: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _loadDelay }
        set { lock.lock(); _loadDelay = newValue; lock.unlock() }
    }
    /// "<trackID>@<startTime>" for every stream that was opened.
    var opened: [String] {
        get { lock.lock(); defer { lock.unlock() }; return _opened }
        set { lock.lock(); _opened = newValue; lock.unlock() }
    }
    func noteOpened(_ entry: String) { lock.lock(); _opened.append(entry); lock.unlock() }
}

/// Plays "audio" for (duration - startTime) seconds of node time, then ends.
final class StreamingAudioSource: @unchecked Sendable {
    let duration: TimeInterval
    private let startTime: TimeInterval
    private var stopped = false
    private var timer: Timer?
    var skippedSeconds: TimeInterval { 0 }

    private init(duration: TimeInterval, startTime: TimeInterval) {
        self.duration = duration
        self.startTime = startTime
    }

    static func make(url: URL, startTime: TimeInterval, duration: TimeInterval,
                     fileTypeHint: AudioFileTypeID = 0, outputFormat: AVAudioFormat,
                     silenceGate: SilenceGate? = nil) async -> StreamingAudioSource? {
        // .../Items/<id>/File or .../Audio/<id>/stream.mp3
        let parts = url.pathComponents
        let trackID = parts.count >= 2 ? parts[parts.count - 2] : "?"
        let delay = SimWorld.shared.loadDelay
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if SimWorld.shared.failing.contains(trackID) { return nil }
        var effectiveStart = startTime
        if let ticks = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "startTimeTicks" })?.value,
           let value = Double(ticks) {
            effectiveStart = value / 10_000_000
        }
        SimWorld.shared.noteOpened("\\(trackID)@\\(Int(effectiveStart.rounded()))")
        return StreamingAudioSource(duration: duration, startTime: effectiveStart)
    }

    func beginScheduling(on node: AVAudioPlayerNode, onEnd: @escaping () -> Void) {
        DispatchQueue.main.async {
            let epoch = node.scheduleEpoch
            let remaining = max(0, self.duration - self.startTime)
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self, weak node] timer in
                guard let self, let node, !self.stopped, node.scheduleEpoch == epoch else { timer.invalidate(); return }
                if node.isPlaying, node.playedSeconds >= remaining {
                    timer.invalidate()
                    onEnd()
                }
            }
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.stopped = true
            self.timer?.invalidate()
        }
    }
}
final class TrackSchedulerNode {
    let player = AVAudioPlayerNode()
    let eq = AVAudioUnitEQ(numberOfBands: 10)
    init(engine: AVAudioEngine) {}
    func attach(to engine: AVAudioEngine) { engine.attach(player); engine.attach(eq) }
    func apply(preset: EQPreset) {}
}
final class StreamingAssetCache {
    init(session: JellyfinSession) {}
    func localFile(for itemID: String, remoteURL: URL) async throws -> URL { throw JellyfinError.notFound }
}
enum DownloadStore {
    static func localURL(for track: Track) -> URL? { nil }
}
protocol AudioSpectrumProviding: AnyObject {
    var spectrum: SpectrumStore { get }
    func retainSpectrum()
    func releaseSpectrum()
}
final class SpectrumStore: @unchecked Sendable {}
final class SpectrumTap {
    private(set) var installs = 0
    private(set) var installed = false
    init(store: SpectrumStore) {}
    func install(on mixer: AVAudioMixerNode) { if !installed { installed = true; installs += 1 } }
    func remove(from mixer: AVAudioMixerNode) { installed = false }
}
'''

# Inside the container the repository is mounted at /w (run.sh); pass
# ENGINE_SIM_ROOT to build somewhere else (e.g. natively on macOS).
package_root = os.environ.get("ENGINE_SIM_ROOT", "/w")
files["Package.swift"] = files["Package.swift"].replace("__ROOT__", package_root)

for name, content in files.items():
    path = os.path.join(out, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write(content)

# Real app-shell files under test. Only Objective-C selectors are rewritten
# (Linux has no ObjC runtime); everything else is byte-identical.
sim = os.path.join(out, "Sources/Sim")
player = open(os.path.join(worktree, "ios/Jellyamp/Services/Audio/AudioEnginePlayer.swift")).read()
player, n = re.subn(
    r"NotificationCenter\.default\.addObserver\(\s*self, selector: #selector\((\w+)\(_:\)\),\s*name: ([^,]+), object: (\w+)\)",
    r"_ = NotificationCenter.default.addObserver(forName: \2, object: \3, queue: nil) { [weak self] note in self?.\1(note) }",
    player)
assert n == 2, n
player = player.replace("@objc private func", "private func")
open(os.path.join(sim, "AudioEnginePlayer.swift"), "w").write(player)
for rel in ["ios/Jellyamp/Services/Audio/PlaybackSupport.swift", "ios/Jellyamp/Features/NowPlaying/PlayerStateModel.swift"]:
    open(os.path.join(sim, os.path.basename(rel)), "w").write(open(os.path.join(worktree, rel)).read())
main_src = os.path.join(os.path.dirname(os.path.abspath(__file__)), "main.swift")
open(os.path.join(sim, "main.swift"), "w").write(open(main_src).read())
print("sim harness written to", out)
