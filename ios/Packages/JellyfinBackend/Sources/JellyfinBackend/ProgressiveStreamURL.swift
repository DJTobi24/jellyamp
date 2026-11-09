import Foundation
import JellyampCore

public extension StreamURLBuilder {
    /// Highest bitrate the MP3 transcode is asked for (the format's ceiling).
    static let maxProgressiveBitrate = 320_000

    /// Stream URL for the `AVAudioEngine` player, which parses a byte stream
    /// itself (`AudioFileStream`) and therefore cannot play HLS playlists.
    ///
    /// - `.directPlay` → the raw original file, as before.
    /// - `.transcode` → `/Audio/{id}/stream.mp3`: a progressive MP3 the parser
    ///   picks up after the first few kilobytes. It is not byte-seekable, so a
    ///   seek passes `startTime` and the server starts encoding there.
    ///
    /// MP3 is chosen over AAC because every `AudioFileStream` version syncs to
    /// it mid-stream and 320 kbit/s is transparent for a data-saver path.
    static func progressiveURL(
        for trackID: String,
        request: StreamRequest,
        startTime: TimeInterval = 0,
        playSessionID: String = UUID().uuidString,
        session: JellyfinSession
    ) -> URL {
        switch request {
        case .directPlay:
            return url(for: trackID, request: .directPlay, session: session)
        case .transcode(_, _, let maxBitrate):
            var components = URLComponents(
                url: session.serverURL.appendingPathComponent("Audio/\(trackID)/stream.mp3"),
                resolvingAgainstBaseURL: false
            )!
            var items = [
                URLQueryItem(name: "api_key", value: session.accessToken ?? ""),
                URLQueryItem(name: "deviceId", value: session.deviceID),
                URLQueryItem(name: "playSessionId", value: playSessionID),
                URLQueryItem(name: "audioCodec", value: "mp3"),
                URLQueryItem(name: "audioBitRate", value: String(min(max(maxBitrate, 64_000), maxProgressiveBitrate))),
                URLQueryItem(name: "audioSampleRate", value: "44100"),
                URLQueryItem(name: "maxAudioChannels", value: "2"),
            ]
            if startTime > 0 {
                items.append(URLQueryItem(name: "startTimeTicks", value: String(Int64(startTime * 10_000_000))))
            }
            components.queryItems = items
            return components.url!
        }
    }
}
