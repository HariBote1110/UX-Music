import Foundation

@MainActor
final class LocalLibrary: ObservableObject {

    @Published private(set) var songs: [WatchSongMeta] = []

    private static let metaKey = "ux_wear_local_library"

    static let documentsDirectory: URL = {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }()

    static func fileURL(for song: Song) -> URL {
        documentsDirectory.appendingPathComponent("\(song.id).\(song.fileType)")
    }

    static func fileURL(for meta: WatchSongMeta) -> URL {
        documentsDirectory.appendingPathComponent("\(meta.id).\(meta.fileType)")
    }

    init() {
        loadFromDisk()
    }

    func addSong(_ meta: WatchSongMeta, fileURL _: URL) {
        guard !songs.contains(where: { $0.id == meta.id }) else { return }
        songs.append(meta)
        saveToDisk()
    }

    func removeSong(id: String) {
        guard let idx = songs.firstIndex(where: { $0.id == id }) else { return }
        let meta = songs[idx]
        songs.remove(at: idx)
        saveToDisk()
        // Delete audio file
        let url = Self.documentsDirectory.appendingPathComponent("\(meta.id).\(meta.fileType)")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard
            let data = UserDefaults.standard.data(forKey: Self.metaKey),
            let loaded = try? JSONDecoder().decode([WatchSongMeta].self, from: data)
        else { return }

        // Verify files still exist on disk
        songs = loaded.filter {
            FileManager.default.fileExists(
                atPath: Self.documentsDirectory.appendingPathComponent("\($0.id).\($0.fileType)").path
            )
        }
    }

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(songs) else { return }
        UserDefaults.standard.set(data, forKey: Self.metaKey)
    }
}

// MARK: - WatchSongMeta → Song bridge (for AudioPlayerService compatibility)

extension AudioPlayerService {
    func play(_ meta: WatchSongMeta, queue metas: [WatchSongMeta]) {
        // Convert WatchSongMeta → Song (minimal fields needed for playback)
        let songs = metas.map { $0.toSong() }
        let target = meta.toSong()
        play(target, queue: songs)
    }
}

extension WatchSongMeta {
    func toSong() -> Song {
        Song(
            id: id,
            path: LocalLibrary.fileURL(for: self).path,
            title: title,
            artist: artist,
            album: album,
            albumArtist: "",
            year: 0,
            genre: "",
            duration: duration,
            trackNumber: 0,
            discNumber: 0,
            fileSize: 0,
            fileType: fileType,
            sampleRate: nil,
            bitDepth: nil
        )
    }
}
