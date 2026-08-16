import ImageIO
import UIKit
import XCTest
@testable import UX_Music_Mobile

/// Baseline micro-benchmarks for the suspects raised by `mobile_perf_research/notes/static-review-2026-08.md`.
/// Research tooling only — these are measurements, not behaviour specs, so they are exempt from the
/// TDD discipline that governs `UX-Music-MobileTests`'s other files.
///
/// ## Gating
/// Every test starts with `XCTSkipUnless(ProcessInfo.processInfo.environment["UXM_PERF"] == "1")` so
/// the normal 444-test suite skips them by default. `xcodebuild test` only forwards environment
/// variables to the test process when they are prefixed `TEST_RUNNER_`, so enabling the gate needs:
///
///     TEST_RUNNER_UXM_PERF=1 xcodebuild -scheme UX-Music-Mobile \
///         -destination 'platform=iOS Simulator,name=iPhone 17' \
///         -only-testing:UX-Music-MobileTests/PerformanceBenchmarkTests test
///
/// This was confirmed empirically (see `mobile_perf_research/notes/baseline-microbench-2026-08.md`,
/// 手順 section) — `TEST_RUNNER_UXM_PERF=1` arrives as `ProcessInfo.environment["UXM_PERF"] == "1"`
/// inside the simulator's test process.
@MainActor
final class PerformanceBenchmarkTests: XCTestCase {
    // MARK: - Shared fixtures

    /// `UserDefaults.standard`'s value for `AppConstants.downloadedSongsMetaKey` before this test
    /// touched it, restored in `tearDown` so other tests (and a developer's simulator state) are
    /// unaffected by whatever this file registers under that key.
    private var savedDownloadedSongsMeta: Data?

    override func setUp() {
        super.setUp()
        savedDownloadedSongsMeta = UserDefaults.standard.data(forKey: AppConstants.downloadedSongsMetaKey)
    }

    // MARK: - (a) DownloadManager.isDownloaded scaling

    /// Registers `n` synthetic downloaded songs (dummy `<stem>.m4a` files under the manager's real
    /// tracks directory, same as `AppModelDownloadTests`'s isolation-free pattern), returns the
    /// manager and the song ids for the caller to `measure {}` and clean up.
    private func makeDownloadedFixture(n: Int, label: String) throws -> (DownloadManager, [String]) {
        let dm = DownloadManager()
        var ids: [String] = []
        ids.reserveCapacity(n)
        for i in 0 ..< n {
            let id = "perf-bench-\(label)-\(UUID().uuidString.prefix(8))-\(i)"
            let song = Song(
                id: id,
                path: "/lib/\(id).m4a",
                title: "Track \(i)",
                artist: "Artist \(i % 40)",
                album: "Album \(i % 40)",
                albumArtist: "Artist \(i % 40)",
                artworkId: ""
            )
            try Data("dummy-audio-bytes".utf8).write(to: dm.localFileURL(songId: id))
            dm.register(song)
            ids.append(id)
        }
        return (dm, ids)
    }

    private func cleanUpDownloadedFixture(_ dm: DownloadManager, ids: [String]) {
        for id in ids {
            dm.remove(songId: id)
        }
    }

    /// One render pass of an n-row list calls `isDownloaded` once per row (see
    /// `SongRowDownloadTrailing.body` in `Views/SongRowView.swift`).
    private func measureIsDownloadedScaling(n: Int) throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UXM_PERF"] == "1", "Set UXM_PERF=1 to run performance benchmarks")

        let (dm, ids) = try makeDownloadedFixture(n: n, label: "isdl\(n)")
        defer { cleanUpDownloadedFixture(dm, ids: ids) }

        measure {
            for id in ids {
                _ = dm.isDownloaded(songId: id)
            }
        }
    }

    func testIsDownloadedScaling_n100() throws {
        try measureIsDownloadedScaling(n: 100)
    }

    func testIsDownloadedScaling_n400() throws {
        try measureIsDownloadedScaling(n: 400)
    }

    func testIsDownloadedScaling_n800() throws {
        try measureIsDownloadedScaling(n: 800)
    }

    // MARK: - (b) Library search/group per-keystroke cost

    /// ~40 albums x 20 songs = 800 songs, varied artists — mirrors the fixture size/shape requested
    /// for the search benchmark.
    private static func makeSynthetic800SongLibrary() -> [Song] {
        var songs: [Song] = []
        songs.reserveCapacity(800)
        let albumCount = 40
        let songsPerAlbum = 20
        for albumIndex in 0 ..< albumCount {
            let albumArtist = "Artist \(albumIndex % 25)"
            let albumTitle = "Album \(albumIndex)"
            for trackIndex in 0 ..< songsPerAlbum {
                let id = "perf-bench-lib-\(albumIndex)-\(trackIndex)"
                songs.append(
                    Song(
                        id: id,
                        path: "/lib/\(albumTitle)/\(trackIndex).m4a",
                        title: "Song \(trackIndex) of \(albumTitle)",
                        artist: "Artist \((albumIndex + trackIndex) % 25)",
                        album: albumTitle,
                        albumArtist: albumArtist,
                        duration: Double(120 + trackIndex * 7),
                        trackNumber: trackIndex + 1,
                        artworkId: "artwork-\(albumIndex)"
                    )
                )
            }
        }
        return songs
    }

    /// Replicates `LocalLibraryScreen`'s `sortedSongs` / `searchedSongs` / `searchedAlbums` /
    /// `searchedArtists` computed vars — all four recompute on every `searchQuery` keystroke because
    /// all four view segments live under the same `body` (per static review finding #2).
    func testLibrarySearchKeystrokeCost() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UXM_PERF"] == "1", "Set UXM_PERF=1 to run performance benchmarks")

        let downloaded = Self.makeSynthetic800SongLibrary()
        let query = "Song 5"

        measure {
            let sortedSongs = LibrarySortOrder.album.sorted(downloaded)
            _ = SongSearchFilter.filter(sortedSongs, query: query)

            let albums = AlbumSortOrder.name.sorted(Album.fromSongs(downloaded))
            _ = albums.filter { !SongSearchFilter.filter($0.songs, query: query).isEmpty }

            let artists = ArtistSortOrder.name.sorted(Artist.fromSongs(downloaded))
            _ = artists.filter { !SongSearchFilter.filter($0.songs, query: query).isEmpty }
        }
    }

    // MARK: - (c) DownloadManager init (loadMeta) startup cost

    /// With an n=800 fixture already on disk and its meta blob already in `UserDefaults` (same
    /// state a relaunch would find), times constructing a fresh `DownloadManager` — i.e. `loadMeta`'s
    /// JSON decode + two directory enumerations + per-song linear match.
    func testDownloadManagerInitCost() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UXM_PERF"] == "1", "Set UXM_PERF=1 to run performance benchmarks")

        let (setupDM, ids) = try makeDownloadedFixture(n: 800, label: "init")
        defer { cleanUpDownloadedFixture(setupDM, ids: ids) }

        measure {
            _ = DownloadManager()
        }
    }

    // MARK: - (d) Artwork full-res decode vs downsampled

    private var syntheticArtworkURL: URL!

    private func makeSyntheticArtworkJPEGIfNeeded() throws -> URL {
        if let syntheticArtworkURL, FileManager.default.fileExists(atPath: syntheticArtworkURL.path) {
            return syntheticArtworkURL
        }
        let size = CGSize(width: 3000, height: 3000)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let colours = [UIColor.systemBlue.cgColor, UIColor.systemPink.cgColor, UIColor.systemYellow.cgColor]
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colours as CFArray,
                locations: [0, 0.5, 1]
            ) else { return }
            context.cgContext.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("perf-bench-artwork-\(UUID().uuidString).jpg")
        try data.write(to: url, options: .atomic)
        syntheticArtworkURL = url
        return url
    }

    override func tearDownWithError() throws {
        if let syntheticArtworkURL {
            try? FileManager.default.removeItem(at: syntheticArtworkURL)
        }
        syntheticArtworkURL = nil

        if let savedDownloadedSongsMeta {
            UserDefaults.standard.set(savedDownloadedSongsMeta, forKey: AppConstants.downloadedSongsMetaKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppConstants.downloadedSongsMetaKey)
        }
        savedDownloadedSongsMeta = nil

        try super.tearDownWithError()
    }

    /// Forces the image to actually decode (CGImage decoding on first use/draw is lazy) by drawing
    /// it into a throwaway 1x1 bitmap context — same trick used to force-decode elsewhere in the app.
    private func forceDecode(_ cgImage: CGImage) {
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Mirrors `RemoteArtworkCaching.swift`'s current pattern: `UIImage(contentsOfFile:)` decodes at
    /// full resolution even though rows display artwork at 44-180pt.
    func testArtworkDecodeFullResolution() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UXM_PERF"] == "1", "Set UXM_PERF=1 to run performance benchmarks")

        let url = try makeSyntheticArtworkJPEGIfNeeded()

        measure {
            guard let image = UIImage(contentsOfFile: url.path), let cgImage = image.cgImage else {
                XCTFail("failed to decode synthetic artwork")
                return
            }
            forceDecode(cgImage)
        }
    }

    /// Mirrors `ArtworkPaletteExtractor.swift`'s pattern (the "good" reference in the static review):
    /// `CGImageSourceCreateThumbnailAtIndex` downsamples during decode instead of after.
    func testArtworkDecodeDownsampledThumbnail() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["UXM_PERF"] == "1", "Set UXM_PERF=1 to run performance benchmarks")

        let url = try makeSyntheticArtworkJPEGIfNeeded()

        measure {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                XCTFail("failed to create image source for synthetic artwork")
                return
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 96,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                XCTFail("failed to create thumbnail for synthetic artwork")
                return
            }
            forceDecode(thumbnail)
        }
    }
}
