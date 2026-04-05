import CryptoKit
import Foundation
import UIKit

/// On-disk JPEG/PNG/WebP bytes for Wear `/wear/artwork` previews (Remote Library grids and rows).
/// Separate from `DownloadManager`’s `DownloadedArtwork` so `pruneOrphanArtworkFiles` does not delete browsed jackets.
struct RemoteArtworkPreviewCache: Sendable {
    let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    init(sharedCachesDirectory fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        rootURL = base.appendingPathComponent("RemoteArtworkPreview", isDirectory: true)
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    static let shared = RemoteArtworkPreviewCache(sharedCachesDirectory: .default)

    static func storageFileName(for artworkId: String) -> String {
        let digest = SHA256.hash(data: Data(artworkId.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex).img"
    }

    func fileURLIfPresent(artworkId: String) -> URL? {
        guard !artworkId.isEmpty else { return nil }
        let u = rootURL.appendingPathComponent(Self.storageFileName(for: artworkId))
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func store(data: Data, artworkId: String) throws {
        guard !artworkId.isEmpty, !data.isEmpty else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let dest = rootURL.appendingPathComponent(Self.storageFileName(for: artworkId))
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try data.write(to: dest, options: .atomic)
    }
}

// MARK: - Load + coalesce in-flight fetches

enum WearRemoteArtworkImageLoader {
    static func loadUIImage(artworkId: String, urlString: String) async -> UIImage? {
        await WearRemoteArtworkFetchCoordinator.shared.image(artworkId: artworkId, urlString: urlString)
    }
}

/// In-memory: Wear returned 404 for this `artworkId`, so skip repeat HTTP and use bundled default.
private actor WearRemoteArtworkMissCache {
    static let shared = WearRemoteArtworkMissCache()

    private var ids: Set<String> = []

    func contains(_ artworkId: String) -> Bool {
        guard !artworkId.isEmpty else { return false }
        return ids.contains(artworkId)
    }

    func recordMissing(_ artworkId: String) {
        guard !artworkId.isEmpty else { return }
        ids.insert(artworkId)
    }
}

private func wearRemoteArtworkLoadDirect(
    artworkId: String,
    urlString: String,
    cache: RemoteArtworkPreviewCache
) async -> UIImage? {
    if !artworkId.isEmpty, let cached = cache.fileURLIfPresent(artworkId: artworkId) {
        return await Task.detached(priority: .utility) {
            UIImage(contentsOfFile: cached.path) ?? WearDefaultArtwork.uiImage()
        }.value
    }
    if !artworkId.isEmpty, await WearRemoteArtworkMissCache.shared.contains(artworkId) {
        return WearDefaultArtwork.uiImage()
    }
    guard !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
    if url.isFileURL {
        return await Task.detached(priority: .utility) {
            UIImage(contentsOfFile: url.path) ?? WearDefaultArtwork.uiImage()
        }.value
    }
    guard url.scheme == "http" || url.scheme == "https" else { return nil }
    do {
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        let (data, response) = try await WearLANURLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return WearDefaultArtwork.uiImage()
        }
        let resolvedId = !artworkId.isEmpty ? artworkId : WearAPIClient.artworkId(fromArtworkEndpointURL: url)
        if http.statusCode == 404 {
            if let resolvedId {
                await WearRemoteArtworkMissCache.shared.recordMissing(resolvedId)
            }
            return WearDefaultArtwork.uiImage()
        }
        guard (200 ... 299).contains(http.statusCode) else {
            return WearDefaultArtwork.uiImage()
        }
        if let resolvedId {
            try? cache.store(data: data, artworkId: resolvedId)
        }
        let decoded = await Task.detached(priority: .utility) {
            UIImage(data: data)
        }.value
        return decoded ?? WearDefaultArtwork.uiImage()
    } catch {
        return WearDefaultArtwork.uiImage()
    }
}

private actor WearRemoteArtworkFetchCoordinator {
    static let shared = WearRemoteArtworkFetchCoordinator()

    private var tasks: [String: Task<UIImage?, Never>] = [:]

    func image(artworkId: String, urlString: String, cache: RemoteArtworkPreviewCache = .shared) async -> UIImage? {
        let key = Self.cacheKey(artworkId: artworkId, urlString: urlString)
        if let existing = tasks[key] {
            return await existing.value
        }
        let task = Task {
            await wearRemoteArtworkLoadDirect(artworkId: artworkId, urlString: urlString, cache: cache)
        }
        tasks[key] = task
        let value = await task.value
        tasks[key] = nil
        return value
    }

    private static func cacheKey(artworkId: String, urlString: String) -> String {
        if !artworkId.isEmpty {
            return "id:\(artworkId)"
        }
        return "url:\(urlString)"
    }
}
