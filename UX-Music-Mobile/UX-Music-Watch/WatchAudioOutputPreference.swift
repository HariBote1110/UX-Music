import Foundation

/// The user's preferred audio output for Watch playback.
enum WatchAudioOutputPreference: String, CaseIterable, Codable, Equatable {
    case automatic
    case bluetooth
    case speaker

    static let userDefaultsKey = "watchAudioOutputPreference"
}
