import Foundation

/// User-created playlist persisted on device (`UserDefaults` JSON via `PlaylistStore`).
struct Playlist: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var songIds: [String]
    let createdAt: Date
    var updatedAt: Date
}
