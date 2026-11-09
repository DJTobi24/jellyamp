import Foundation
import JellyampCore

/// Builds Jellyfin audio stream URLs from a `StreamRequest` decision, mirroring
/// the approach Finamp uses (it drives the same `AVPlayer` under the hood):
/// direct play streams the raw original file, transcoding goes over HLS. Pure
/// function of session + request → URL, fully unit-tested.
public enum StreamURLBuilder {
    public static func url(for trackID: String, request: StreamRequest, session: JellyfinSession) -> URL {
        switch request {
        case .directPlay:
            return directFileURL(for: trackID, session: session)
        case .transcode(let codec, _, let maxBitrate):
            return hlsURL(for: trackID, codec: codec, maxBitrate: maxBitrate, session: session)
        }
    }

    /// Raw original file (`/Items/{id}/File`): byte-range seekable and served
    /// with a correct `Content-Type`, so `AVPlayer` resolves it immediately.
    /// `/Audio/{id}/universal` could transcode and is not byte-seekable, which
    /// leaves AVPlayer stuck "waiting to minimize stalls" behind a proxy.
    private static func directFileURL(for trackID: String, session: JellyfinSession) -> URL {
        var components = URLComponents(
            url: session.serverURL.appendingPathComponent("Items/\(trackID)/File"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "api_key", value: session.accessToken ?? "")]
        return components.url!
    }

    /// HLS transcode (`/Audio/{id}/main.m3u8`): AVPlayer plays `.m3u8` natively
    /// (adaptive + seekable), unlike a progressive transcode it can neither
    /// reliably buffer nor seek.
    private static func hlsURL(for trackID: String, codec: String, maxBitrate: Int, session: JellyfinSession) -> URL {
        var components = URLComponents(
            url: session.serverURL.appendingPathComponent("Audio/\(trackID)/main.m3u8"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: session.accessToken ?? ""),
            URLQueryItem(name: "deviceId", value: session.deviceID),
            URLQueryItem(name: "playSessionId", value: UUID().uuidString),
            URLQueryItem(name: "audioCodec", value: codec),
            URLQueryItem(name: "audioSampleRate", value: "44100"),
            URLQueryItem(name: "maxAudioBitDepth", value: "16"),
            URLQueryItem(name: "audioBitRate", value: String(maxBitrate)),
            URLQueryItem(name: "maxAudioChannels", value: "2"),
        ]
        return components.url!
    }

    /// Original file for an offline download (`/Items/{id}/Download`).
    ///
    /// Checked against Jellyfin 10.10.7: `/Items/{id}/Download`,
    /// `/Items/{id}/File` and `/Audio/{id}/stream?static=true` all return the
    /// byte-identical original with `Content-Length`, `Accept-Ranges: bytes`
    /// and `Last-Modified` (no `ETag`); `Range` gives 206 and a stale
    /// `If-Range` date gives a full 200, so URLSession resume data is safe.
    /// `/Download` is the one meant for this: it honours the per-user "allow
    /// media downloads" policy (403 when disabled) and names the file in
    /// `Content-Disposition`. It needs auth (401 without); the token goes in
    /// `api_key` like the stream URLs, because a background transfer is
    /// re-issued by the system and must not depend on request headers
    /// surviving redirects or reverse proxies. `HEAD` is not supported (405).
    public static func downloadURL(for trackID: String, session: JellyfinSession) -> URL {
        var components = URLComponents(
            url: session.serverURL.appendingPathComponent("Items/\(trackID)/Download"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "api_key", value: session.accessToken ?? "")]
        return components.url!
    }

    /// Progressive transcode (`/Audio/{id}/stream.{container}`): one HTTP
    /// response with the re-encoded audio, for players that read a byte stream
    /// themselves and cannot follow an HLS playlist. Not byte-seekable (no
    /// `Content-Length`, no ranges); to seek, request it again with another
    /// `startTime` — the stream then starts at that position.
    public static func progressiveTranscodeURL(
        for trackID: String,
        codec: String,
        container: String,
        maxBitrate: Int,
        startTime: TimeInterval = 0,
        session: JellyfinSession
    ) -> URL {
        var components = URLComponents(
            url: session.serverURL.appendingPathComponent("Audio/\(trackID)/stream.\(container)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: session.accessToken ?? ""),
            URLQueryItem(name: "deviceId", value: session.deviceID),
            URLQueryItem(name: "playSessionId", value: UUID().uuidString),
            URLQueryItem(name: "audioCodec", value: codec),
            URLQueryItem(name: "audioSampleRate", value: "44100"),
            URLQueryItem(name: "audioBitRate", value: String(maxBitrate)),
            URLQueryItem(name: "maxAudioChannels", value: "2"),
        ]
        let url = components.url!
        return startTime > 0 ? self.url(url, seekingTo: startTime) : url
    }

    /// Same URL with `startTimeTicks`: seeks a *progressive* transcode
    /// (`progressiveTranscodeURL`), which then starts at that position.
    ///
    /// An HLS URL (`url(for:request:)` for `.transcode`) is returned without
    /// it. HLS is seeked by the player, which fetches the segment it needs
    /// from the playlist of the whole track; with `startTimeTicks` Jellyfin
    /// still serves that same playlist but then refuses every segment in it
    /// (400, "StartTimeTicks is not allowed").
    public static func url(_ base: URL, seekingTo seconds: TimeInterval) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var items = (components.queryItems ?? []).filter { $0.name != "startTimeTicks" }
        if !base.path.lowercased().hasSuffix(".m3u8") {
            items.append(URLQueryItem(name: "startTimeTicks", value: String(Int64(seconds * 10_000_000))))
        }
        components.queryItems = items
        return components.url!
    }
}

/// Builds `/Items/{id}/Images/…` URLs.
public enum ImageURLBuilder {
    public enum ImageType: String {
        case primary = "Primary"
        case backdrop = "Backdrop"
    }

    public static func url(itemID: String, tag: String?, type: ImageType = .primary, maxWidth: Int, session: JellyfinSession) -> URL {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "fillWidth", value: String(maxWidth)),
            URLQueryItem(name: "quality", value: "90"),
        ]
        if let tag {
            query.append(URLQueryItem(name: "tag", value: tag))
        }
        var components = URLComponents(
            url: session.serverURL.appendingPathComponent("Items/\(itemID)/Images/\(type.rawValue)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = query
        return components.url!
    }

    /// Cover to store next to downloads. Fixed width (enough for the full-screen
    /// player at 3x) and no `tag`, so one file
    /// per item serves every size the UI asks for; images need no auth.
    public static func offlineArtworkURL(itemID: String, session: JellyfinSession) -> URL {
        url(itemID: itemID, tag: nil, maxWidth: 1000, session: session)
    }

    /// Best image URL for a track: its own primary image, else its album's.
    public static func trackImageURL(track: Track, maxWidth: Int, session: JellyfinSession) -> URL? {
        if let albumID = track.albumID {
            return url(itemID: albumID, tag: track.imageTag, maxWidth: maxWidth, session: session)
        }
        guard track.imageTag != nil else { return nil }
        return url(itemID: track.id, tag: track.imageTag, maxWidth: maxWidth, session: session)
    }
}
