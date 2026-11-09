import Foundation
import UIKit
import JellyampCore
import JellyfinBackend

/// Loads list artwork for CarPlay rows.
///
/// CarPlay rejects (or silently scales, depending on the head unit) images
/// larger than `CPListItem.maximumImageSize`, and list rows are created for
/// the whole list at once rather than as they scroll into view. So images
/// are requested from Jellyfin at exactly the pixel size needed, decoded and
/// cropped off the main thread, cached in memory, and fetched a few at a time.
@MainActor
final class CarPlayArtworkLoader {
    private let cache = NSCache<NSString, UIImage>()
    private var waiting: [String: [(UIImage) -> Void]] = [:]
    private let urlSession: URLSession

    init() {
        cache.countLimit = 400
        let configuration = URLSessionConfiguration.default
        // A list can ask for a few hundred covers in one go; let URLSession
        // queue them instead of opening that many connections to the server.
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 15
        // The disk cache keeps covers available without a connection
        // (Downloads tab in a tunnel).
        configuration.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 64 * 1024 * 1024)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        urlSession = URLSession(configuration: configuration)
    }

    /// Calls `completion` on the main actor with a square image of
    /// `pointSize`, or never if the item has no artwork / the load fails —
    /// the row then simply keeps its placeholder symbol.
    func load(
        _ artwork: CarPlayArtworkRef,
        session: JellyfinSession,
        pointSize: CGSize,
        scale: CGFloat,
        completion: @escaping (UIImage) -> Void
    ) {
        let side = max(pointSize.width, pointSize.height)
        guard side > 0 else { return }
        let pixelWidth = Int((side * max(scale, 1)).rounded(.up))
        let key = "\(artwork.itemID)|\(artwork.imageTag ?? "-")|\(pixelWidth)"

        if let cached = cache.object(forKey: key as NSString) {
            completion(cached)
            return
        }
        if waiting[key] != nil {
            waiting[key]?.append(completion)
            return
        }
        waiting[key] = [completion]

        let url = ImageURLBuilder.url(itemID: artwork.itemID, tag: artwork.imageTag, maxWidth: pixelWidth, session: session)
        let urlSession = self.urlSession
        Task { [weak self] in
            let image = await Self.fetch(url: url, urlSession: urlSession, pointSize: pointSize, scale: scale)
            self?.finish(key: key, image: image)
        }
    }

    private func finish(key: String, image: UIImage?) {
        let callbacks = waiting.removeValue(forKey: key) ?? []
        guard let image else { return }
        cache.setObject(image, forKey: key as NSString)
        for callback in callbacks {
            callback(image)
        }
    }

    func removeAll() {
        cache.removeAllObjects()
        waiting.removeAll()
    }

    /// Download + decode + crop, off the main actor.
    private nonisolated static func fetch(url: URL, urlSession: URLSession, pointSize: CGSize, scale: CGFloat) async -> UIImage? {
        guard let (data, response) = try? await urlSession.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return nil
        }
        guard let source = UIImage(data: data), source.size.width > 0, source.size.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = max(scale, 1)
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pointSize, format: format)
        return renderer.image { _ in
            // Aspect-fill: covers are not always square, rows are.
            let ratio = max(pointSize.width / source.size.width, pointSize.height / source.size.height)
            let drawSize = CGSize(width: source.size.width * ratio, height: source.size.height * ratio)
            let origin = CGPoint(x: (pointSize.width - drawSize.width) / 2, y: (pointSize.height - drawSize.height) / 2)
            source.draw(in: CGRect(origin: origin, size: drawSize))
        }
    }
}
