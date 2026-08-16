import Foundation

enum AppConstants {
    static let defaultServerPort = 8765
    static let defaultTargetLoudness: Double = -18
    static let wearPathPrefix = "/wear"
    static let syncMDNSServiceType = "_uxmusic-sync._tcp."
    /// Phase 3-1 Connect-style TV receiver (`TVRemoteControlServer`) advertises itself under this
    /// service type — distinct from `syncMDNSServiceType` since a TV is not a Sync peer (see
    /// `progress/tvos-connect.md`).
    static let tvRemoteMDNSServiceType = "_uxmusic-remote._tcp."
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
    /// Persisted `DownloadAudioQuality.rawValue` for new downloads (Settings → ダウンロード音質).
    static let downloadAudioQualityKey = "uxmusic.download.audioQuality"
    /// Persisted `DownloadAACBitrate.rawValue` for new AAC downloads (Settings → ダウンロード音質).
    static let downloadAACBitrateKey = "uxmusic.download.aacBitrate"
    /// Persisted snapshot (id + title) of `WatchTransferBridge.queue` entries not yet `.sent`/
    /// `.failed`, so a relaunched iPhone app can resume them — see `WatchTransferQueuePersistence`
    /// and `WatchTransferRestoreReconciliation`.
    static let watchTransferPendingQueueKey = "uxmusic.watchTransfer.pendingQueue"
}
