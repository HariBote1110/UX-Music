import Foundation

/// Tracks "library membership" for songs that have no local file — today this is exclusively
/// YouTube songs added from `RemoteLibraryScreen` ("ライブラリに追加"). This is deliberately
/// separate from `DownloadManager` (which conflates "has metadata" with "file exists on disk"):
/// a YouTube song belongs to the local Library purely by having its `Song` metadata persisted
/// here, since playback goes through the official embed player rather than a downloaded file.
@MainActor
final class LibraryMembershipStore {
    private(set) var songs: [String: Song] = [:]

    init() {
        loadMeta()
    }

    func contains(songId: String) -> Bool {
        songs[songId] != nil
    }

    func add(_ song: Song) {
        songs[song.id] = song
        saveMeta()
    }

    func remove(songId: String) {
        songs.removeValue(forKey: songId)
        saveMeta()
    }

    private func loadMeta() {
        guard let data = UserDefaults.standard.data(forKey: AppConstants.youtubeLibrarySongsMetaKey),
              let list = try? JSONDecoder().decode([Song].self, from: data)
        else { return }
        for song in list {
            songs[song.id] = song
        }
    }

    private func saveMeta() {
        let list = Array(songs.values)
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: AppConstants.youtubeLibrarySongsMetaKey)
        }
    }
}
