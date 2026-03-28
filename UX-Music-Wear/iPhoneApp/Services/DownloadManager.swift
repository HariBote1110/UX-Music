import Foundation

/// Handles bulk pre-fetching of audio files from the UX Music server.
/// Individual song downloads are handled inside WatchBridge; this class
/// is used for batch album/playlist pre-caching.
@MainActor
final class DownloadManager: ObservableObject {

    @Published var totalBytes: Int64 = 0
    @Published var downloadedBytes: Int64 = 0

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(downloadedBytes) / Double(totalBytes)
    }

    private var client: MusicServerClient?

    func configure(baseURL: URL) {
        client = MusicServerClient(baseURL: baseURL)
    }

    func downloadSongs(_ songs: [Song]) async throws -> [Song: URL] {
        guard let client else { throw DownloadError.notConfigured }

        totalBytes = songs.reduce(0) { $0 + $1.fileSize }
        downloadedBytes = 0

        var result: [Song: URL] = [:]
        for song in songs {
            let url = try await client.downloadFile(songID: song.id)
            result[song] = url
            downloadedBytes += song.fileSize
        }
        return result
    }

    enum DownloadError: LocalizedError {
        case notConfigured
        var errorDescription: String? { "Download manager not configured with a server URL" }
    }
}
