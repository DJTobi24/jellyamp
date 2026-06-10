import Foundation

/// User-configurable behaviour, persisted via `SettingsStoring`.
public struct AppSettings: Codable, Equatable, Sendable {
    public var crossfadeDuration: TimeInterval
    public var loudnessLevelingEnabled: Bool
    public var loudnessPreampDB: Double
    public var silenceCompressionEnabled: Bool
    public var playbackProfile: PlaybackProfileSettings
    public var activeEQPresetID: String?
    public var sonicServerURL: URL?
    public var sleepTimerFadeOut: TimeInterval

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
