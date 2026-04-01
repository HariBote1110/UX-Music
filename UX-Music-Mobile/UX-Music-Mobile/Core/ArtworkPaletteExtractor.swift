import Foundation
import ImageIO
import SwiftUI

/// RGB backdrop colours derived from artwork (sRGB, 0…1). Used only for now playing visuals.
struct ArtworkPlaybackPalette: Equatable {
    /// Upper / leading gradient stop (already darkened for text contrast).
    var top: (Double, Double, Double)
    /// Lower / trailing gradient stop.
    var bottom: (Double, Double, Double)
    /// Slider tint and soft radial highlights.
    var accent: (Double, Double, Double)

    var topColor: Color { Color(red: top.0, green: top.1, blue: top.2) }
    var bottomColor: Color { Color(red: bottom.0, green: bottom.1, blue: bottom.2) }
    var accentColor: Color { Color(red: accent.0, green: accent.1, blue: accent.2) }

    static func == (lhs: ArtworkPlaybackPalette, rhs: ArtworkPlaybackPalette) -> Bool {
        lhs.top == rhs.top && lhs.bottom == rhs.bottom && lhs.accent == rhs.accent
    }
}

private final class ArtworkPaletteBox {
    let palette: ArtworkPlaybackPalette
    init(palette: ArtworkPlaybackPalette) { self.palette = palette }
}

enum ArtworkPaletteExtractor {
    private static let cache = NSCache<NSString, ArtworkPaletteBox>()
    private static let thumbnailMaxPixel: CGFloat = 128

    /// Fetches artwork (or reads `file:`), builds a small thumbnail, samples top/bottom regions. Thread-safe cache.
    static func palette(forArtworkURL url: URL) async -> ArtworkPlaybackPalette? {
        let key = url.absoluteString as NSString
        if let boxed = cache.object(forKey: key) {
            return boxed.palette
        }

        return await Task.detached(priority: .utility) {
            let data: Data?
            if url.isFileURL {
                data = try? Data(contentsOf: url)
            } else {
                data = try? await fetchData(from: url)
            }
            guard let data, let palette = paletteFromImageData(data) else { return nil }
            cache.setObject(ArtworkPaletteBox(palette: palette), forKey: key)
            return palette
        }.value
    }

    private static func fetchData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad
        let (data, response) = try await WearLANURLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private nonisolated static func paletteFromImageData(_ data: Data) -> ArtworkPlaybackPalette? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return palette(from: cgImage)
    }

    private nonisolated static func palette(from cgImage: CGImage) -> ArtworkPlaybackPalette? {
        let w = cgImage.width
        let h = cgImage.height
        guard w >= 2, h >= 2 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = w * bytesPerPixel
        var buffer = [UInt8](repeating: 0, count: h * bytesPerRow)

        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let ctx = CGContext(
            data: &buffer,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        let midX = w / 2
        guard let leadingAvg = averageRGB(
            buffer: buffer,
            x0: 0,
            x1: midX,
            y0: 0,
            y1: h,
            bytesPerRow: bytesPerRow
        ),
        let trailingAvg = averageRGB(
            buffer: buffer,
            x0: midX,
            x1: w,
            y0: 0,
            y1: h,
            bytesPerRow: bytesPerRow
        )
        else { return nil }

        let accentRaw = mix(leadingAvg, trailingAvg, t: 0.5)
        let accent = boostSaturation(accentRaw, amount: 1.25)

        return ArtworkPlaybackPalette(
            top: backdropColour(from: leadingAvg),
            bottom: backdropColour(from: trailingAvg),
            accent: (
                clamp(accent.0 * 0.55 + 0.25),
                clamp(accent.1 * 0.55 + 0.25),
                clamp(accent.2 * 0.55 + 0.25)
            )
        )
    }

    private nonisolated static func averageRGB(
        buffer: [UInt8],
        x0: Int,
        x1: Int,
        y0: Int,
        y1: Int,
        bytesPerRow: Int
    ) -> (Double, Double, Double)? {
        var sr: Double = 0
        var sg: Double = 0
        var sb: Double = 0
        var n: Double = 0
        for y in y0 ..< y1 {
            for x in x0 ..< x1 {
                let o = y * bytesPerRow + x * 4
                let a = Double(buffer[o + 3]) / 255.0
                guard a > 0.02 else { continue }
                let r = Double(buffer[o]) / 255.0 / a
                let g = Double(buffer[o + 1]) / 255.0 / a
                let b = Double(buffer[o + 2]) / 255.0 / a
                sr += r
                sg += g
                sb += b
                n += 1
            }
        }
        guard n > 0 else { return nil }
        return (sr / n, sg / n, sb / n)
    }

    private nonisolated static func mix(
        _ a: (Double, Double, Double),
        _ b: (Double, Double, Double),
        t: Double
    ) -> (Double, Double, Double) {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }

    private nonisolated static func backdropColour(from rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        let r = rgb.0 * 0.42 + 0.03
        let g = rgb.1 * 0.42 + 0.03
        let b = rgb.2 * 0.42 + 0.03
        return (clamp(r), clamp(g), clamp(b))
    }

    private nonisolated static func boostSaturation(
        _ rgb: (Double, Double, Double),
        amount: Double
    ) -> (Double, Double, Double) {
        let l = (rgb.0 + rgb.1 + rgb.2) / 3.0
        func pull(_ c: Double) -> Double {
            l + (c - l) * amount
        }
        return (clamp(pull(rgb.0)), clamp(pull(rgb.1)), clamp(pull(rgb.2)))
    }

    private nonisolated static func clamp(_ v: Double) -> Double {
        min(1, max(0, v))
    }
}
