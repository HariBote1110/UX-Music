import Foundation

enum PlaylistStoreError: Error, Equatable {
    case emptyName
    case duplicateName
    case notFound
    case invalidPlaylistOrder
}

private struct PlaylistsEnvelope: Codable {
    var playlists: [Playlist]
    var order: [String]
}

/// Local playlist persistence (desktop-equivalent CRUD on device).
@MainActor
final class PlaylistStore {
    private let defaults: UserDefaults
    private let persistenceKey: String
    private var playlistsById: [String: Playlist] = [:]
    private var order: [String] = []

    init(defaults: UserDefaults = .standard, persistenceKey: String = AppConstants.playlistsPersistenceKey) {
        self.defaults = defaults
        self.persistenceKey = persistenceKey
        load()
    }

    func load() {
        guard let data = defaults.data(forKey: persistenceKey),
              let env = try? JSONDecoder().decode(PlaylistsEnvelope.self, from: data)
        else {
            playlistsById = [:]
            order = []
            return
        }
        playlistsById = Dictionary(uniqueKeysWithValues: env.playlists.map { ($0.id, $0) })
        let validIds = Set(playlistsById.keys)
        order = env.order.filter { validIds.contains($0) }
        for pl in env.playlists where !order.contains(pl.id) {
            order.append(pl.id)
        }
        persist()
    }

    func orderedPlaylists() -> [Playlist] {
        order.compactMap { playlistsById[$0] }
    }

    func playlist(id: String) -> Playlist? {
        playlistsById[id]
    }

    @discardableResult
    func createPlaylist(name: String) throws -> Playlist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PlaylistStoreError.emptyName }
        if playlistsById.values.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw PlaylistStoreError.duplicateName
        }
        let now = Date()
        let id = UUID().uuidString
        let pl = Playlist(id: id, name: trimmed, songIds: [], createdAt: now, updatedAt: now)
        playlistsById[id] = pl
        order.append(id)
        persist()
        return pl
    }

    func deletePlaylist(id: String) throws {
        guard playlistsById.removeValue(forKey: id) != nil else { throw PlaylistStoreError.notFound }
        order.removeAll { $0 == id }
        persist()
    }

    func renamePlaylist(id: String, newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PlaylistStoreError.emptyName }
        guard var pl = playlistsById[id] else { throw PlaylistStoreError.notFound }
        if playlistsById.values.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw PlaylistStoreError.duplicateName
        }
        pl.name = trimmed
        pl.updatedAt = Date()
        playlistsById[id] = pl
        persist()
    }

    func addSongIds(to playlistId: String, songIds: [String]) throws {
        guard var pl = playlistsById[playlistId] else { throw PlaylistStoreError.notFound }
        var existing = Set(pl.songIds)
        for sid in songIds where !existing.contains(sid) {
            pl.songIds.append(sid)
            existing.insert(sid)
        }
        pl.updatedAt = Date()
        playlistsById[playlistId] = pl
        persist()
    }

    func removeSongIds(from playlistId: String, songIds: [String]) throws {
        guard var pl = playlistsById[playlistId] else { throw PlaylistStoreError.notFound }
        let remove = Set(songIds)
        pl.songIds.removeAll { remove.contains($0) }
        pl.updatedAt = Date()
        playlistsById[playlistId] = pl
        persist()
    }

    func setSongOrder(playlistId: String, orderedIds: [String]) throws {
        guard var pl = playlistsById[playlistId] else { throw PlaylistStoreError.notFound }
        let currentSet = Set(pl.songIds)
        var seen = Set<String>()
        var next: [String] = []
        for sid in orderedIds where currentSet.contains(sid) && !seen.contains(sid) {
            next.append(sid)
            seen.insert(sid)
        }
        for sid in pl.songIds where !seen.contains(sid) {
            next.append(sid)
        }
        pl.songIds = next
        pl.updatedAt = Date()
        playlistsById[playlistId] = pl
        persist()
    }

    func setPlaylistOrder(ids: [String]) throws {
        let valid = Set(playlistsById.keys)
        guard ids.count == valid.count, Set(ids) == valid else {
            throw PlaylistStoreError.invalidPlaylistOrder
        }
        order = ids
        persist()
    }

    private func persist() {
        let env = PlaylistsEnvelope(playlists: Array(playlistsById.values), order: order)
        if let data = try? JSONEncoder().encode(env) {
            defaults.set(data, forKey: persistenceKey)
        }
    }
}
