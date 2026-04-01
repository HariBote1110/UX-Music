import Foundation
import Observation

enum LibraryLoadState: Equatable {
    case idle
    case loading
    case loaded([Song])
    case failed(String)
}

/// Central app state (Riverpod providers folded into one `@Observable` model).
@MainActor
@Observable
final class AppModel {
    var serverConfig: ServerConfig {
        didSet { persistSettings() }
    }

    var libraryState: LibraryLoadState = .idle
    var loudness: [String: Double] = [:]

    /// Drives the full-screen now playing sheet (lives on `AppModel` so `tabViewBottomAccessory` can update presentation reliably).
    var isNowPlayingSheetPresented = false

    /// songId → 0...1 while downloading
    var downloadProgress: [String: Double] = [:]
    /// Last failure from `downloadSong` / `downloadAlbum` (shown on Remote Library).
    var downloadError: String?

    let downloadManager: DownloadManager
    let player: MusicPlayerService
    let playlistStore: PlaylistStore
    let favouriteSongStore: FavouriteSongStore

    /// Locally persisted playlists (order matches `playlistStore`).
    private(set) var playlists: [Playlist] = []
    /// Mirror of `favouriteSongStore.orderedIds` so `@Observable` invalidates views when favourites change.
    private(set) var favouriteSongIds: [String] = []

    init(playlistStore: PlaylistStore? = nil) {
        serverConfig = Self.loadSettings()
        downloadManager = DownloadManager()
        self.playlistStore = playlistStore ?? PlaylistStore()
        favouriteSongStore = FavouriteSongStore()
        favouriteSongIds = favouriteSongStore.orderedIds
        player = MusicPlayerService()
        player.targetLoudness = AppConstants.defaultTargetLoudness
        player.loadArtworkImage = { [weak self] song in
            guard let self else { return nil }
            let s = self.artworkURL(for: song.artworkId)
            guard !s.isEmpty, let url = URL(string: s) else { return nil }
            return await NowPlayingArtworkImageLoader.uiImage(from: url)
        }
        refreshPlaylists()
    }

    private static func loadSettings() -> ServerConfig {
        guard let data = UserDefaults.standard.data(forKey: AppConstants.serverConfigKey),
              let cfg = try? JSONDecoder().decode(ServerConfig.self, from: data)
        else { return ServerConfig() }
        return cfg
    }

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(serverConfig) {
            UserDefaults.standard.set(data, forKey: AppConstants.serverConfigKey)
        }
    }

    func client() -> WearAPIClient {
        WearAPIClient(baseURLString: serverConfig.baseURLString)
    }

    /// Remote Wear URL, or `file://` when the jacket was cached under `DownloadedArtwork/` after a download.
    func artworkURL(for artworkId: String) -> String {
        guard !artworkId.isEmpty else { return "" }
        if let local = downloadManager.localArtworkFileURLIfPresent(artworkId: artworkId) {
            return local.absoluteString
        }
        return client().artworkURL(artworkId: artworkId)
    }

    /// Applies a pairing URL from QR or deep link. Returns whether configuration changed.
    @discardableResult
    func applyPairingURL(_ url: URL) -> Bool {
        guard let cfg = ServerConfig.fromPairingURL(url), cfg.isConfigured else { return false }
        serverConfig = cfg
        return true
    }

    func refreshLibrary() async {
        libraryState = .loading
        do {
            let c = client()
            let songs = try await c.fetchSongs()
            libraryState = .loaded(songs)
            if let map = try? await c.fetchLoudness() {
                loudness = map
                player.loudnessMap = map
                player.refreshVolumeForCurrentSong()
            }
        } catch is CancellationError {
            // Tab switched away (LazyTabRoot) or view replaced; avoid stuck `.loading`.
            if case .loading = libraryState {
                libraryState = .idle
            }
        } catch {
            libraryState = .failed(error.localizedDescription)
        }
    }

    func refreshLoudnessOnly() async {
        do {
            let map = try await client().fetchLoudness()
            loudness = map
            player.loudnessMap = map
            player.refreshVolumeForCurrentSong()
        } catch {
            // Keep previous map (Flutter behaviour)
        }
    }

    func downloadSong(_ song: Song) async {
        guard downloadProgress[song.id] == nil else { return }
        downloadError = nil
        downloadProgress[song.id] = 0
        let dest = downloadManager.localFileURL(songId: song.id)
        do {
            try await client().downloadFile(songId: song.id, to: dest, preferOriginalAudio: true) { received, total in
                Task { @MainActor in
                    if total > 0 {
                        self.downloadProgress[song.id] = Double(received) / Double(total)
                    }
                }
            }
            downloadManager.register(song)
            await cacheArtworkAfterDownloadIfNeeded(for: song)
        } catch {
            downloadError = error.localizedDescription
        }
        downloadProgress.removeValue(forKey: song.id)
    }

    /// Downloads every track in `album` that is not already local, in album order (sequential).
    func downloadAlbum(_ album: Album) async {
        for song in album.songs {
            guard !downloadManager.isDownloaded(songId: song.id) else { continue }
            await downloadSong(song)
        }
    }

    func albumHasTracksToDownload(_ album: Album) -> Bool {
        album.songs.contains { !downloadManager.isDownloaded(songId: $0.id) }
    }

    private func cacheArtworkAfterDownloadIfNeeded(for song: Song) async {
        guard !song.artworkId.isEmpty else { return }
        guard !downloadManager.hasLocalArtwork(artworkId: song.artworkId) else { return }
        do {
            let dest = downloadManager.localArtworkDestinationURL(artworkId: song.artworkId)
            try await client().downloadArtwork(artworkId: song.artworkId, to: dest)
        } catch {
            // Optional: list rows still use remote artwork when reachable.
        }
    }

    // MARK: - Playlists (local)

    func refreshPlaylists() {
        playlists = playlistStore.orderedPlaylists()
    }

    func createPlaylist(name: String) throws {
        _ = try playlistStore.createPlaylist(name: name)
        refreshPlaylists()
    }

    func deletePlaylist(id: String) throws {
        try playlistStore.deletePlaylist(id: id)
        refreshPlaylists()
    }

    func renamePlaylist(id: String, newName: String) throws {
        try playlistStore.renamePlaylist(id: id, newName: newName)
        refreshPlaylists()
    }

    func addSongsToPlaylist(playlistId: String, songIds: [String]) throws {
        try playlistStore.addSongIds(to: playlistId, songIds: songIds)
        refreshPlaylists()
    }

    func removeSongsFromPlaylist(playlistId: String, songIds: [String]) throws {
        try playlistStore.removeSongIds(from: playlistId, songIds: songIds)
        refreshPlaylists()
    }

    func movePlaylists(fromOffsets: IndexSet, toOffset: Int) throws {
        var ids = playlists.map(\.id)
        ids.move(fromOffsets: fromOffsets, toOffset: toOffset)
        try playlistStore.setPlaylistOrder(ids: ids)
        refreshPlaylists()
    }

    func moveSongs(inPlaylistId playlistId: String, fromOffsets: IndexSet, toOffset: Int) throws {
        guard let pl = playlistStore.playlist(id: playlistId) else { throw PlaylistStoreError.notFound }
        var ids = pl.songIds
        ids.move(fromOffsets: fromOffsets, toOffset: toOffset)
        try playlistStore.setSongOrder(playlistId: playlistId, orderedIds: ids)
        refreshPlaylists()
    }

    /// Maps `playlist.songIds` to downloaded `Song`s; missing IDs are skipped (removed tracks).
    func resolvedSongs(for playlist: Playlist) -> [Song] {
        playlist.songIds.compactMap { downloadManager.downloadedSongs[$0] }
    }

    func artworkIdForPlaylist(_ playlist: Playlist) -> String {
        for sid in playlist.songIds {
            if let s = downloadManager.downloadedSongs[sid], !s.artworkId.isEmpty {
                return s.artworkId
            }
        }
        return ""
    }

    // MARK: - Favourites (local)

    func isFavouriteSong(songId: String) -> Bool {
        favouriteSongIds.contains(songId)
    }

    func toggleFavourite(songId: String) {
        favouriteSongStore.toggle(songId: songId)
        favouriteSongIds = favouriteSongStore.orderedIds
    }

    func removeFavourite(songId: String) {
        favouriteSongStore.remove(songId: songId)
        favouriteSongIds = favouriteSongStore.orderedIds
    }

    /// Favourite ids mapped to downloaded `Song`s (missing downloads are omitted).
    func favouriteSongsForPlayback() -> [Song] {
        favouriteSongIds.compactMap { downloadManager.downloadedSongs[$0] }
    }
}
