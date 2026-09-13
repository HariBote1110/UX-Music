import Foundation

enum PlaybackCollectionKind: String, Codable, Sendable {
    case album
    case playlist
    case desktopPlaylist
}

struct PlaybackCollectionRef: Hashable, Codable, Sendable {
    let kind: PlaybackCollectionKind
    let key: String
}

enum CollectionShufflePreference: String, Codable, Sendable {
    case on
    case off
}
