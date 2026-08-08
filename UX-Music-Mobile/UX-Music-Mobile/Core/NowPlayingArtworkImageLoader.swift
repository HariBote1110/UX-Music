import Foundation
import UIKit

/// Loads jacket bytes for `MPNowPlayingInfoCenter` (local `file:` or Wear artwork URL).
enum NowPlayingArtworkImageLoader {
    static func uiImage(from url: URL) async -> UIImage? {
        if url.isFileURL {
            return await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: url.path) ?? RemoteDefaultArtwork.uiImage()
            }.value
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
            if let remoteId = RemoteAPIClient.artworkId(fromArtworkEndpointURL: url) {
                try? RemoteArtworkPreviewCache.shared.store(data: data, artworkId: remoteId)
            }
            let img = await Task.detached(priority: .utility) {
                UIImage(data: data)
            }.value
            return img ?? RemoteDefaultArtwork.uiImage()
        } catch {
            return RemoteDefaultArtwork.uiImage()
        }
    }
}
