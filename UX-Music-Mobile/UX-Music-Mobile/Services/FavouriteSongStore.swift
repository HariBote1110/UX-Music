import Foundation

/// Persists favourite song ids in display order (British spelling in comments only; type names stay ASCII).
@MainActor
final class FavouriteSongStore {
    private let defaults: UserDefaults
    private let persistenceKey: String
    private(set) var orderedIds: [String] = []

    init(defaults: UserDefaults = .standard, persistenceKey: String = AppConstants.favouriteSongIdsKey) {
        self.defaults = defaults
        self.persistenceKey = persistenceKey
        load()
    }

    func load() {
        guard let data = defaults.data(forKey: persistenceKey) else {
            orderedIds = []
            return
        }
        guard let ids = try? JSONDecoder().decode([String].self, from: data) else {
            // Keep the undecodable bytes so the next save does not silently discard them; the oldest copy wins.
            let backupKey = persistenceKey + ".undecodable-backup"
            if defaults.data(forKey: backupKey) == nil {
                defaults.set(data, forKey: backupKey)
            }
            orderedIds = []
            return
        }
        orderedIds = ids
    }

    private func save() {
        if let data = try? JSONEncoder().encode(orderedIds) {
            defaults.set(data, forKey: persistenceKey)
        }
    }

    func contains(songId: String) -> Bool {
        orderedIds.contains(songId)
    }

    func toggle(songId: String) {
        if let idx = orderedIds.firstIndex(of: songId) {
            orderedIds.remove(at: idx)
        } else {
            orderedIds.append(songId)
        }
        save()
    }

    func remove(songId: String) {
        orderedIds.removeAll { $0 == songId }
        save()
    }
}
