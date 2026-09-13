import Foundation
import Observation

/// Per-device shuffle defaults for collections. A missing entry means to use the user's baseline.
@MainActor
@Observable
final class CollectionShufflePreferenceStore {
    private let defaults: UserDefaults
    private let persistenceKey: String
    private var preferences: [PlaybackCollectionRef: CollectionShufflePreference] = [:]

    init(
        defaults: UserDefaults = .standard,
        persistenceKey: String = "uxmusic.playback.collectionShufflePreferences"
    ) {
        self.defaults = defaults
        self.persistenceKey = persistenceKey
        load()
    }

    func preference(for reference: PlaybackCollectionRef) -> CollectionShufflePreference? {
        preferences[reference]
    }

    func setPreference(_ preference: CollectionShufflePreference?, for reference: PlaybackCollectionRef) {
        if let preference {
            preferences[reference] = preference
        } else {
            preferences.removeValue(forKey: reference)
        }
        persist()
    }

    private func load() {
        guard let data = defaults.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([PlaybackCollectionRef: CollectionShufflePreference].self, from: data)
        else {
            return
        }
        preferences = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(preferences) {
            defaults.set(data, forKey: persistenceKey)
        }
    }
}
