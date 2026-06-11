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

    /// Seek into a transcoded stream: same URL with `startTimeTicks`.
    public static func url(_ base: URL, seekingTo seconds: TimeInterval) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        var items = (components.queryItems ?? []).filter { $0.name != "startTimeTicks" }
        items.append(URLQueryItem(name: "startTimeTicks", value: String(Int64(seconds * 10_000_000))))
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

    /// Best image URL for a track: its own primary image, else its album's.
    public static func trackImageURL(track: Track, maxWidth: Int, session: JellyfinSession) -> URL? {
        if let albumID = track.albumID {
            return url(itemID: albumID, tag: track.imageTag, maxWidth: maxWidth, session: session)
        }
        guard track.imageTag != nil else { return nil }
        return url(itemID: track.id, tag: track.imageTag, maxWidth: maxWidth, session: session)
    }
}
