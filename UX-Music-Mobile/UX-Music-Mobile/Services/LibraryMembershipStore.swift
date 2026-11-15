import Foundation

/// Tracks "library membership" for songs that have no local file — today this is exclusively
/// YouTube songs added from `RemoteLibraryScreen` ("ライブラリに追加"). This is deliberately
/// separate from `DownloadManager` (which conflates "has metadata" with "file exists on disk"):
/// a YouTube song belongs to the local Library purely by having its `Song` metadata persisted
/// here, since playback goes through the official embed player rather than a downloaded file.
@MainActor
final class LibraryMembershipStore {
    private(set) var songs: [String: Song] = [:]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        let key = AppConstants.youtubeLibrarySongsMetaKey
        guard let data = defaults.data(forKey: key) else { return }
        guard let list = try? JSONDecoder().decode([Song].self, from: data) else {
            // Keep the undecodable bytes so the next save does not silently discard them; the oldest copy wins.
            let backupKey = key + ".undecodable-backup"
            if defaults.data(forKey: backupKey) == nil {
                defaults.set(data, forKey: backupKey)
            }
            return
        }
        for song in list {
            songs[song.id] = song
        }
    }

    private func saveMeta() {
        let list = Array(songs.values)
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: AppConstants.youtubeLibrarySongsMetaKey)
        }
    }
}
