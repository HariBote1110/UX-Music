import Foundation
import UIKit

/// Loads jacket bytes for `MPNowPlayingInfoCenter` (local `file:` or Wear artwork URL).
enum NowPlayingArtworkImageLoader {
    static func uiImage(from url: URL) async -> UIImage? {
        if url.isFileURL {
            return await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: url.path) ?? WearDefaultArtwork.uiImage()
            }.value
        }
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            let (data, response) = try await WearLANURLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return WearDefaultArtwork.uiImage()
            }
            if http.statusCode == 404 {
                return WearDefaultArtwork.uiImage()
            }
            guard (200 ... 299).contains(http.statusCode) else {
                return WearDefaultArtwork.uiImage()
            }
            if let remoteId = WearAPIClient.artworkId(fromArtworkEndpointURL: url) {
                try? RemoteArtworkPreviewCache.shared.store(data: data, artworkId: remoteId)
            }
            let img = await Task.detached(priority: .utility) {
                UIImage(data: data)
            }.value
            return img ?? WearDefaultArtwork.uiImage()
        } catch {
            return WearDefaultArtwork.uiImage()
        }
    }
}
