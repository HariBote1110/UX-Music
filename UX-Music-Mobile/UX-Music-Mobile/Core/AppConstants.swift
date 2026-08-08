import Foundation

enum AppConstants {
    static let defaultServerPort = 8765
    static let defaultTargetLoudness: Double = -18
    static let wearPathPrefix = "/wear"
    static let syncMDNSServiceType = "_uxmusic-sync._tcp."
    static let downloadedSongsMetaKey = "downloaded_songs_meta"
    static let serverConfigKey = "server_config"
    /// JSON envelope for user-created playlists (local device).
    static let playlistsPersistenceKey = "local_playlists_v1"
    /// Ordered favourite song ids (downloaded tracks only when resolving for UI).
    static let favouriteSongIdsKey = "favourite_song_ids_v1"
    /// Metadata-only library membership for YouTube songs (no local file — see `LibraryMembershipStore`).
    static let youtubeLibrarySongsMetaKey = "youtube_library_songs_meta_v1"
    /// Persisted `LibrarySortOrder.rawValue` for the local Library song list.
    static let librarySortOrderKey = "uxmusic.library.sortOrder"
    /// Persisted `AlbumSortOrder.rawValue` for the local Library album grid.
    static let albumSortOrderKey = "uxmusic.library.albumSortOrder"
    /// Persisted `ArtistSortOrder.rawValue` for the local Library artist list.
    static let artistSortOrderKey = "uxmusic.library.artistSortOrder"
}
