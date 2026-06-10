import Foundation
import JellyampCore

/// Builds `/Audio/{id}/universal` URLs from a `StreamRequest` decision.
/// Pure function of session + request → URL, fully unit-tested.
public enum StreamURLBuilder {
    /// Containers/codecs we tell the server we accept for direct streaming.
    static let acceptedContainers = "opus,webm|opus,mp3,aac,m4a|aac,m4b|aac,flac,webma,webm|webma,wav,ogg"

    public static func url(for trackID: String, request: StreamRequest, session: JellyfinSession) -> URL {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "userId", value: session.userID ?? ""),
            URLQueryItem(name: "deviceId", value: session.deviceID),
            URLQueryItem(name: "api_key", value: session.accessToken ?? ""),
            URLQueryItem(name: "playSessionId", value: UUID().uuidString),
        ]
        switch request {
        case .directPlay:
            query.append(URLQueryItem(name: "static", value: "true"))
        case .transcode(let codec, let container, let maxBitrate):
            query.append(contentsOf: [
                URLQueryItem(name: "container", value: acceptedContainers),
                URLQueryItem(name: "transcodingContainer", value: container),
                URLQueryItem(name: "transcodingProtocol", value: "http"),
                URLQueryItem(name: "audioCodec", value: codec),
                URLQueryItem(name: "maxStreamingBitrate", value: String(maxBitrate)),
            ])
        }
        var components = URLComponents(
            url: session.serverURL.appendingPathComponent("Audio/\(trackID)/universal"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = query
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
