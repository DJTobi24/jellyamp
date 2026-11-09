import Foundation

/// User-configurable behaviour, persisted via `SettingsStoring`.
///
/// Decoding is tolerant: every key is optional and falls back to its default,
/// so adding a setting never resets what a user already saved.
public struct AppSettings: Codable, Equatable, Sendable {
    public var crossfadeDuration: TimeInterval = 0
    public var loudnessLevelingEnabled: Bool = true
    public var loudnessPreampDB: Double = 0
    public var silenceCompressionEnabled: Bool = false
    public var playbackProfile: PlaybackProfileSettings = PlaybackProfileSettings()
    public var activeEQPresetID: String?
    public var sonicServerURL: URL?
    public var sleepTimerFadeOut: TimeInterval = 10
    /// Autoplay ("radio"): keep playing similar tracks when the queue runs out.
    public var autoplayEnabled: Bool = true
    /// Browse and play only what is downloaded, even when the server is reachable.
    public var offlineModeEnabled: Bool = false
    /// Allow downloads (manual and smart sync) on cellular connections.
    public var downloadsOverCellular: Bool = false
    public var smartSync: SmartSyncRules = SmartSyncRules()
    public var scrobbling: ScrobblingSettings = ScrobblingSettings()
    /// Now Playing visualizer.
    public var visualizerStyle: VisualizerStyle = .bars

    public init(
        crossfadeDuration: TimeInterval = 0,
        loudnessLevelingEnabled: Bool = true,
        loudnessPreampDB: Double = 0,
        silenceCompressionEnabled: Bool = false,
        playbackProfile: PlaybackProfileSettings = PlaybackProfileSettings(),
        activeEQPresetID: String? = nil,
        sonicServerURL: URL? = nil,
        sleepTimerFadeOut: TimeInterval = 10
    ) {
        self.crossfadeDuration = crossfadeDuration
        self.loudnessLevelingEnabled = loudnessLevelingEnabled
        self.loudnessPreampDB = loudnessPreampDB
        self.silenceCompressionEnabled = silenceCompressionEnabled
        self.playbackProfile = playbackProfile
        self.activeEQPresetID = activeEQPresetID
        self.sonicServerURL = sonicServerURL
        self.sleepTimerFadeOut = sleepTimerFadeOut
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        crossfadeDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .crossfadeDuration) ?? d.crossfadeDuration
        loudnessLevelingEnabled = try c.decodeIfPresent(Bool.self, forKey: .loudnessLevelingEnabled) ?? d.loudnessLevelingEnabled
        loudnessPreampDB = try c.decodeIfPresent(Double.self, forKey: .loudnessPreampDB) ?? d.loudnessPreampDB
        silenceCompressionEnabled = try c.decodeIfPresent(Bool.self, forKey: .silenceCompressionEnabled) ?? d.silenceCompressionEnabled
        playbackProfile = try c.decodeIfPresent(PlaybackProfileSettings.self, forKey: .playbackProfile) ?? d.playbackProfile
        activeEQPresetID = try c.decodeIfPresent(String.self, forKey: .activeEQPresetID)
        sonicServerURL = try c.decodeIfPresent(URL.self, forKey: .sonicServerURL)
        sleepTimerFadeOut = try c.decodeIfPresent(TimeInterval.self, forKey: .sleepTimerFadeOut) ?? d.sleepTimerFadeOut
        autoplayEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoplayEnabled) ?? d.autoplayEnabled
        offlineModeEnabled = try c.decodeIfPresent(Bool.self, forKey: .offlineModeEnabled) ?? d.offlineModeEnabled
        downloadsOverCellular = try c.decodeIfPresent(Bool.self, forKey: .downloadsOverCellular) ?? d.downloadsOverCellular
        smartSync = try c.decodeIfPresent(SmartSyncRules.self, forKey: .smartSync) ?? d.smartSync
        scrobbling = try c.decodeIfPresent(ScrobblingSettings.self, forKey: .scrobbling) ?? d.scrobbling
        visualizerStyle = try c.decodeIfPresent(VisualizerStyle.self, forKey: .visualizerStyle) ?? d.visualizerStyle
    }
}

/// Which scrobbling services are on. Tokens / session keys live in the
/// Keychain, never in settings.
public struct ScrobblingSettings: Codable, Equatable, Sendable {
    public var listenBrainzEnabled: Bool
    public var lastFMEnabled: Bool
    /// Display only; set after a successful Last.fm sign-in.
    public var lastFMUsername: String?

    public init(listenBrainzEnabled: Bool = false, lastFMEnabled: Bool = false, lastFMUsername: String? = nil) {
        self.listenBrainzEnabled = listenBrainzEnabled
        self.lastFMEnabled = lastFMEnabled
        self.lastFMUsername = lastFMUsername
    }
}

public enum VisualizerStyle: String, Codable, CaseIterable, Sendable {
    case off
    case bars
    case wave
}

/// Codable mirror of `PlaybackProfile` for persistence.
public struct PlaybackProfileSettings: Codable, Equatable, Sendable {
    public var maxBitrateWifi: Int?
    public var maxBitrateCellular: Int?
    public var forceTranscodeOnCellular: Bool

    public init(maxBitrateWifi: Int? = nil, maxBitrateCellular: Int? = 320_000, forceTranscodeOnCellular: Bool = false) {
        self.maxBitrateWifi = maxBitrateWifi
        self.maxBitrateCellular = maxBitrateCellular
        self.forceTranscodeOnCellular = forceTranscodeOnCellular
    }

    public var profile: PlaybackProfile {
        PlaybackProfile(
            maxBitrateWifi: maxBitrateWifi,
            maxBitrateCellular: maxBitrateCellular,
            forceTranscodeOnCellular: forceTranscodeOnCellular
        )
    }
}
