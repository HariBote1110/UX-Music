import Foundation

enum AppConstants {
    static let defaultServerPort = 8765
    static let defaultTargetLoudness: Double = -18
    static let wearPathPrefix = "/wear"
    static let downloadedSongsMetaKey = "downloaded_songs_meta"
    static let serverConfigKey = "server_config"
    /// JSON envelope for user-created playlists (local device).
    static let playlistsPersistenceKey = "local_playlists_v1"
    /// Ordered favourite song ids (downloaded tracks only when resolving for UI).
    static let favouriteSongIdsKey = "favourite_song_ids_v1"
}
