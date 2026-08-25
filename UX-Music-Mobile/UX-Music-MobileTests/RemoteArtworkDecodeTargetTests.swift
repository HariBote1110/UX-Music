import UIKit
import XCTest
@testable import UX_Music_Mobile

/// `RemoteArtworkDecodeTarget`/`RemoteArtworkDecodedImageCache` — the size-bucketing and
/// cache-key maths behind thumbnail-sized artwork decoding (see
/// `mobile_remote_perf_research/notes/04-summary-and-recommendations.md` H2: grid tiles used to
/// decode remote artwork at full source resolution even at 48pt).
final class RemoteArtworkDecodeTargetTests: XCTestCase {

    // MARK: - Bucketing maths

    func testTileTargetScalesPointsByDisplayScale() {
        let target = RemoteArtworkDecodeTarget.tile(points: 48, scale: 2, granularity: 16)
        guard case .thumbnail(let size) = target else {
            return XCTFail("expected .thumbnail")
        }
        // 48 * 2 = 96, already a multiple of 16.
        XCTAssertEqual(size, CGSize(width: 96, height: 96))
    }

    func testTileTargetRoundsUpToGranularity() {
        let target = RemoteArtworkDecodeTarget.tile(points: 50, scale: 2, granularity: 16)
        guard case .thumbnail(let size) = target else {
            return XCTFail("expected .thumbnail")
        }
        // 50 * 2 = 100 -> rounds up to 112 (next multiple of 16).
        XCTAssertEqual(size, CGSize(width: 112, height: 112))
    }

    func testTileTargetNeverGoesBelowGranularity() {
        let target = RemoteArtworkDecodeTarget.tile(points: 1, scale: 1, granularity: 16)
        guard case .thumbnail(let size) = target else {
            return XCTFail("expected .thumbnail")
        }
        XCTAssertEqual(size, CGSize(width: 16, height: 16))
    }

    // MARK: - Cache key derivation

    func testCacheKeyDiffersBetweenTileAndFullForSameArtwork() {
        let tileKey = RemoteArtworkDecodedImageCache.key(
            artworkId: "abc", urlString: "", target: .tile(points: 48, scale: 2, granularity: 16)
        )
        let fullKey = RemoteArtworkDecodedImageCache.key(artworkId: "abc", urlString: "", target: .full)
        XCTAssertNotEqual(tileKey, fullKey, "tile and full decodes of the same artwork must not evict each other")
    }

    func testCacheKeyDiffersBetweenDifferentTileBuckets() {
        let small = RemoteArtworkDecodedImageCache.key(
            artworkId: "abc", urlString: "", target: .tile(points: 48, scale: 2, granularity: 16)
        )
        let large = RemoteArtworkDecodedImageCache.key(
            artworkId: "abc", urlString: "", target: .tile(points: 280, scale: 2, granularity: 16)
        )
        XCTAssertNotEqual(small, large)
    }

    func testCacheKeySameForEquivalentTargets() {
        let a = RemoteArtworkDecodedImageCache.key(artworkId: "abc", urlString: "", target: .full)
        let b = RemoteArtworkDecodedImageCache.key(artworkId: "abc", urlString: "", target: .full)
        XCTAssertEqual(a, b)
    }

    func testCacheKeyFallsBackToURLWhenArtworkIdEmpty() {
        let a = RemoteArtworkDecodedImageCache.key(artworkId: "", urlString: "https://x/1.jpg", target: .full)
        let b = RemoteArtworkDecodedImageCache.key(artworkId: "", urlString: "https://x/2.jpg", target: .full)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Actual downsampled decode is pixel-bounded

    func testDecodedImageIsBoundedByThumbnailTarget() {
        let largeImage = Self.makeSolidImage(pixelSize: CGSize(width: 2000, height: 2000))
        guard let data = largeImage.pngData() else {
            return XCTFail("failed to encode fixture image")
        }
        let target = RemoteArtworkDecodeTarget.thumbnail(pixelSize: CGSize(width: 96, height: 96))
        guard let decoded = RemoteArtworkDecoding.decode(data: data, target: target) else {
            return XCTFail("expected a decoded image")
        }
        let decodedPixelWidth = decoded.size.width * decoded.scale
        let decodedPixelHeight = decoded.size.height * decoded.scale
        XCTAssertLessThanOrEqual(decodedPixelWidth, 200, "thumbnail decode should not stay at source resolution")
        XCTAssertLessThanOrEqual(decodedPixelHeight, 200)
    }

    func testDecodedImageAtFullTargetKeepsSourceResolution() {
        let image = Self.makeSolidImage(pixelSize: CGSize(width: 40, height: 40))
        guard let data = image.pngData() else {
            return XCTFail("failed to encode fixture image")
        }
        guard let decoded = RemoteArtworkDecoding.decode(data: data, target: .full) else {
            return XCTFail("expected a decoded image")
        }
        XCTAssertEqual(decoded.size.width * decoded.scale, 40, accuracy: 1)
        XCTAssertEqual(decoded.size.height * decoded.scale, 40, accuracy: 1)
    }

    private static func makeSolidImage(pixelSize: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
        return renderer.image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(origin: .zero, size: pixelSize))
        }
    }
}
