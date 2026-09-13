import Foundation

enum PlaybackCollectionShuffleLogic {
    static func effectiveShuffleEnabled(
        baselineShuffleEnabled: Bool,
        preference: CollectionShufflePreference?
    ) -> Bool {
        switch preference {
        case .on:
            return true
        case .off:
            return false
        case nil:
            return baselineShuffleEnabled
        }
    }
}
