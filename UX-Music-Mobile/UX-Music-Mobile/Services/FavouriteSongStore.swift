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
        guard let data = defaults.data(forKey: persistenceKey),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else {
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
