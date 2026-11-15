import Foundation
import UIKit

/// Loads jacket bytes for `MPNowPlayingInfoCenter` (local `file:` or Wear artwork URL).
enum NowPlayingArtworkImageLoader {
    static func uiImage(from url: URL) async -> UIImage? {
        if url.isFileURL {
            let img = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: url.path)
            }.value
            if let img { return img }
            // Only files inside the artwork cache are removed: this branch also serves local library artwork.
            if isInsideArtworkCache(url) {
                try? FileManager.default.removeItem(at: url)
            }
            return RemoteDefaultArtwork.uiImage()
        }
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            let (data, response) = try await RemoteLANURLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return RemoteDefaultArtwork.uiImage()
            }
            if http.statusCode == 404 {
                return RemoteDefaultArtwork.uiImage()
            }
            guard (200 ... 299).contains(http.statusCode) else {
                return RemoteDefaultArtwork.uiImage()
            }
            let (decodable, img) = await Task.detached(priority: .utility) { () -> (Bool, UIImage?) in
                (RemoteArtworkDecoding.isDecodableImage(data), UIImage(data: data))
            }.value
            if decodable, let remoteId = RemoteAPIClient.artworkId(fromArtworkEndpointURL: url) {
                try? RemoteArtworkPreviewCache.shared.store(data: data, artworkId: remoteId)
            }
            return img ?? RemoteDefaultArtwork.uiImage()
        } catch {
            return RemoteDefaultArtwork.uiImage()
        }
    }

    private static func isInsideArtworkCache(_ url: URL) -> Bool {
        let root = RemoteArtworkPreviewCache.shared.rootURL.standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.hasPrefix(root)
    }
}
