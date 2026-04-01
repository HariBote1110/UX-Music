import Foundation
import UIKit

/// Loads jacket bytes for `MPNowPlayingInfoCenter` (local `file:` or Wear artwork URL).
enum NowPlayingArtworkImageLoader {
    static func uiImage(from url: URL) async -> UIImage? {
        if url.isFileURL {
            return await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: url.path)
            }.value
        }
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            let (data, response) = try await WearLANURLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
                return nil
            }
            return await Task.detached(priority: .utility) {
                UIImage(data: data)
            }.value
        } catch {
            return nil
        }
    }
}
