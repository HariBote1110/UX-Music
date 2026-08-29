import CryptoKit
import Foundation
import UIKit

/// On-disk JPEG/PNG/WebP bytes for `/v1/remote/artwork` previews (Remote Library grids and rows).
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

// MARK: - Downsampled decoding

/// Target pixel dimensions to decode Remote artwork at — either a bounded thumbnail size (grid
/// tiles, matched to the tile's on-screen size × display scale) or `.full` (Now Playing / hero
/// views, which want source resolution). Threading this through the load path avoids
/// `UIImage(data:)`/`UIImage(contentsOfFile:)` decoding a full-resolution bitmap for a tiny 48pt
/// grid cell (see `mobile_remote_perf_research/notes/04-summary-and-recommendations.md` H2).
enum RemoteArtworkDecodeTarget: Equatable {
    case full
    case thumbnail(pixelSize: CGSize)

    /// Buckets `points × scale` up to the nearest `granularity` px per axis so visually-similar
    /// tile sizes (e.g. a grid re-flowing by a few points on rotation) share one cache/decode
    /// target instead of each fractional size minting its own.
    static func tile(points: CGFloat, scale: CGFloat, granularity: CGFloat = 16) -> RemoteArtworkDecodeTarget {
        let px = points * scale
        let bucketed = (px / granularity).rounded(.up) * granularity
        let side = max(bucketed, granularity)
        return .thumbnail(pixelSize: CGSize(width: side, height: side))
    }

    /// Cache-key suffix distinguishing this decode target so a small tile and a full-resolution
    /// decode of the same artwork never evict each other from `RemoteArtworkDecodedImageCache`.
    var cacheKeySuffix: String {
        switch self {
        case .full: return "full"
        case .thumbnail(let size): return "t\(Int(size.width))x\(Int(size.height))"
        }
    }
}

/// Pure decode step (no I/O, no caching) — kept separate so it is directly unit-testable with an
/// in-memory fixture image rather than needing a real HTTP/disk round trip.
enum RemoteArtworkDecoding {
    static func decode(data: Data, target: RemoteArtworkDecodeTarget) -> UIImage? {
        guard let source = UIImage(data: data) else { return nil }
        switch target {
        case .full:
            return source
        case .thumbnail(let pixelSize):
            return source.preparingThumbnail(of: pixelSize) ?? source
        }
    }

    static func decode(contentsOfFile path: String, target: RemoteArtworkDecodeTarget) -> UIImage? {
        guard let source = UIImage(contentsOfFile: path) else { return nil }
        switch target {
        case .full:
            return source
        case .thumbnail(let pixelSize):
            return source.preparingThumbnail(of: pixelSize) ?? source
        }
    }
}

/// In-memory LRU of already-decoded artwork, keyed by artwork identity **and** decode target so a
/// grid-tile thumbnail and a full-resolution Now Playing decode of the same artwork coexist rather
/// than evicting each other. Cell reuse while scrolling a grid re-runs `ArtworkImageView.task(id:)`
/// (its `@State private var loaded` resets), so without this every scroll pass re-decoded from disk.
enum RemoteArtworkDecodedImageCache {
    static let shared = ArtworkMemoryCache<UIImage>(capacity: 300)

    static func key(artworkId: String, urlString: String, target: RemoteArtworkDecodeTarget) -> String {
        let idPart = artworkId.isEmpty ? "url:\(urlString)" : "id:\(artworkId)"
        return "\(idPart)|\(target.cacheKeySuffix)"
    }
}

// MARK: - Load + coalesce in-flight fetches

enum RemoteArtworkImageLoader {
    static func loadUIImage(
        artworkId: String,
        urlString: String,
        target: RemoteArtworkDecodeTarget = .full
    ) async -> UIImage? {
        await RemoteArtworkFetchCoordinator.shared.image(artworkId: artworkId, urlString: urlString, target: target)
    }
}

/// In-memory: Wear returned 404 for this `artworkId`, so skip repeat HTTP and use bundled default.
private actor RemoteArtworkMissCache {
    static let shared = RemoteArtworkMissCache()

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
    target: RemoteArtworkDecodeTarget,
    cache: RemoteArtworkPreviewCache
) async -> UIImage? {
    if !artworkId.isEmpty, let cached = cache.fileURLIfPresent(artworkId: artworkId) {
        return await Task.detached(priority: .utility) {
            RemoteArtworkDecoding.decode(contentsOfFile: cached.path, target: target) ?? RemoteDefaultArtwork.uiImage()
        }.value
    }
    if !artworkId.isEmpty, await RemoteArtworkMissCache.shared.contains(artworkId) {
        return RemoteDefaultArtwork.uiImage()
    }
    guard !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
    if url.isFileURL {
        return await Task.detached(priority: .utility) {
            RemoteArtworkDecoding.decode(contentsOfFile: url.path, target: target) ?? RemoteDefaultArtwork.uiImage()
        }.value
    }
    guard url.scheme == "http" || url.scheme == "https" else { return nil }
    do {
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        let (data, response) = try await RemoteLANURLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return RemoteDefaultArtwork.uiImage()
        }
        let resolvedId = !artworkId.isEmpty ? artworkId : RemoteAPIClient.artworkId(fromArtworkEndpointURL: url)
        if http.statusCode == 404 {
            if let resolvedId {
                await RemoteArtworkMissCache.shared.recordMissing(resolvedId)
            }
            return RemoteDefaultArtwork.uiImage()
        }
        guard (200 ... 299).contains(http.statusCode) else {
            return RemoteDefaultArtwork.uiImage()
        }
        if let resolvedId {
            try? cache.store(data: data, artworkId: resolvedId)
        }
        let decoded = await Task.detached(priority: .utility) {
            RemoteArtworkDecoding.decode(data: data, target: target)
        }.value
        return decoded ?? RemoteDefaultArtwork.uiImage()
    } catch {
        return RemoteDefaultArtwork.uiImage()
    }
}

private actor RemoteArtworkFetchCoordinator {
    static let shared = RemoteArtworkFetchCoordinator()

    private var tasks: [String: Task<UIImage?, Never>] = [:]

    func image(
        artworkId: String,
        urlString: String,
        target: RemoteArtworkDecodeTarget = .full,
        cache: RemoteArtworkPreviewCache = .shared
    ) async -> UIImage? {
        let memoryKey = RemoteArtworkDecodedImageCache.key(artworkId: artworkId, urlString: urlString, target: target)
        if let cached = RemoteArtworkDecodedImageCache.shared.value(forKey: memoryKey) {
            return cached
        }
        let taskKey = "\(Self.cacheKey(artworkId: artworkId, urlString: urlString))|\(target.cacheKeySuffix)"
        if let existing = tasks[taskKey] {
            return await existing.value
        }
        let task = Task {
            await wearRemoteArtworkLoadDirect(artworkId: artworkId, urlString: urlString, target: target, cache: cache)
        }
        tasks[taskKey] = task
        let value = await task.value
        tasks[taskKey] = nil
        if let value {
            RemoteArtworkDecodedImageCache.shared.setValue(value, forKey: memoryKey)
        }
        return value
    }

    private static func cacheKey(artworkId: String, urlString: String) -> String {
        if !artworkId.isEmpty {
            return "id:\(artworkId)"
        }
        return "url:\(urlString)"
    }
}
