import Foundation
import Observation

enum LibraryLoadState: Equatable {
    case idle
    case loading
    case loaded([Song])
    case failed(String)
}

enum DesktopPlaylistMissingPolicy: String, CaseIterable, Identifiable, Sendable {
    /// Keep desktop order; drop tracks that are not stored locally.
    case omitMissingDownloads
    /// Download each missing track from the desktop, then build the full playlist (failed downloads are skipped).
    case downloadMissingTracks

    var id: String { rawValue }
}

struct DesktopPlaylistImportOutcome: Equatable, Sendable {
    var playlistsCreated: Int
    var playlistsSkippedEmpty: Int
    var desktopPathsMissingFromLibrary: Int
    var tracksOmittedNotDownloaded: Int
    var failedTrackDownloads: Int
}

/// How to render on-device lyrics in the dedicated lyrics screen.
enum LocalLyricsDisplayMode: Equatable {
    case plain(String)
    case synced([LRCParser.TimedLine])
}

enum DesktopPlaylistImportError: LocalizedError {
    case serverNotConfigured

    var errorDescription: String? {
        switch self {
        case .serverNotConfigured:
            return "設定でデスクトップとペアリングしてください。"
        }
    }
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

    /// Message from the most recent failed `redeemPairing` call (invalid/expired secret, unreachable
    /// host, …), shown by Settings next to the pairing field.
    var pairingError: String?

    /// Drives the full-screen now playing sheet (lives on `AppModel` so `tabViewBottomAccessory` can update presentation reliably).
    var isNowPlayingSheetPresented = false

    /// songId → 0...1 while downloading
    var downloadProgress: [String: Double] = [:]
    /// Last failure from `downloadSong` / `downloadAlbum` (shown on Remote Library).
    var downloadError: String?

    /// Bumped when local download metadata changes so `@Observable` invalidates library views that do not read `downloadProgress`.
    private(set) var downloadLibraryRevision: Int = 0

    let downloadManager: DownloadManager
    let lyricsFileStore: LyricsFileStore
    let player: MusicPlayerService
    let playlistStore: PlaylistStore
    let favouriteSongStore: FavouriteSongStore
    let watchTransferBridge: WatchTransferBridge

    /// Locally persisted playlists (order matches `playlistStore`).
    private(set) var playlists: [Playlist] = []
    /// Mirror of `favouriteSongStore.orderedIds` so `@Observable` invalidates views when favourites change.
    private(set) var favouriteSongIds: [String] = []

    init(playlistStore: PlaylistStore? = nil, lyricsFileStore: LyricsFileStore? = nil) {
        serverConfig = Self.loadSettings()
        downloadManager = DownloadManager()
        watchTransferBridge = WatchTransferBridge(downloadManager: downloadManager)
        // Activated here (app model construction, i.e. at process launch) rather than from a
        // view's onAppear: WCSession.activate() completes asynchronously, and a `send` requested
        // before that completion must see the bridge already mid-activation to be queued correctly
        // (see WatchTransferBridge.send / handleActivationCompletion).
        watchTransferBridge.activate()
        self.lyricsFileStore = lyricsFileStore ?? LyricsFileStore()
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

    private func touchDownloadLibrary() {
        downloadLibraryRevision &+= 1
    }

    /// Local tracks in album / disc / track order (not global title sort — avoids scrambled queues and grids).
    var sortedDownloadedSongsForLibrary: [Song] {
        _ = downloadLibraryRevision
        return downloadManager.downloadedSongs.values.sorted(by: Song.libraryFlatDisplayOrderAscending)
    }

    func isSongDownloaded(songId: String) -> Bool {
        _ = downloadLibraryRevision
        return downloadManager.isDownloaded(songId: songId)
    }

    func removeDownloadedSong(songId: String) {
        lyricsFileStore.remove(for: songId)
        downloadManager.remove(songId: songId)
        touchDownloadLibrary()
    }

    /// Downloaded songs not already in the playlist (for “Add songs”); observes `downloadLibraryRevision`.
    func downloadedSongsEligibleForPlaylist(excludingPlaylistSongIds songIds: Set<String>) -> [Song] {
        _ = downloadLibraryRevision
        return downloadManager.downloadedSongs.values
            .filter { !songIds.contains($0.id) }
            .sorted(by: Song.libraryFlatDisplayOrderAscending)
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

    /// Overridable in tests to inject a mocked `URLSession` (see `RemoteLANURLSession`).
    var urlSession: URLSession = RemoteLANURLSession.shared

    func client() -> RemoteAPIClient {
        RemoteAPIClient(baseURLString: serverConfig.baseURLString, token: serverConfig.token, session: urlSession)
    }

    /// Runs `operation` against the current server; on a connection-level failure (`URLError`),
    /// retries each `fallbackHosts` entry in order and promotes the first one that succeeds to
    /// `serverConfig.host`. HTTP-status errors (`RemoteAPIError`) mean the server was reached, so
    /// they are not retried against fallback hosts.
    func withFailover<T>(_ operation: @Sendable (RemoteAPIClient) async throws -> T) async throws -> T {
        let primaryHost = serverConfig.host
        let fallbackHosts = serverConfig.fallbackHosts
        let hostsToTry = [primaryHost] + fallbackHosts

        var lastError: Error?
        for (index, host) in hostsToTry.enumerated() {
            let candidateConfig = ServerConfig(host: host, port: serverConfig.port, token: serverConfig.token)
            let candidateClient = RemoteAPIClient(
                baseURLString: candidateConfig.baseURLString,
                token: candidateConfig.token,
                session: urlSession
            )
            do {
                let result = try await operation(candidateClient)
                if index > 0 {
                    // Promote the host that just succeeded to primary; demote the rest (in their
                    // existing relative order) to fallbackHosts.
                    var remaining = hostsToTry
                    remaining.remove(at: index)
                    serverConfig.host = host
                    serverConfig.fallbackHosts = remaining
                }
                return result
            } catch let error as URLError {
                lastError = error
                continue
            } catch {
                // Reached the server (e.g. an HTTP-status error) — do not fail over.
                throw error
            }
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    /// Remote Wear URL, or `file://` when the jacket was cached under `DownloadedArtwork/` after a download.
    func artworkURL(for artworkId: String) -> String {
        guard !artworkId.isEmpty else { return "" }
        if let local = downloadManager.localArtworkFileURLIfPresent(artworkId: artworkId) {
            return local.absoluteString
        }
        if let preview = RemoteArtworkPreviewCache.shared.fileURLIfPresent(artworkId: artworkId) {
            return preview.absoluteString
        }
        return client().artworkURL(artworkId: artworkId)
    }

    /// Applies a pairing URL from QR or deep link: redeems the embedded one-time secret for a
    /// device-specific auth token via `POST /v1/pairing/redeem`. Returns whether pairing succeeded;
    /// on failure, `pairingError` is set to a user-facing message.
    @discardableResult
    func applyPairingURL(_ url: URL) async -> Bool {
        guard let request = ServerConfig.pairingRequest(fromPairingURL: url) else { return false }
        return await redeemPairing(host: request.host, port: request.port, secret: request.secret)
    }

    /// Redeems a pairing secret (from QR or manual entry) for a device token and, on success, saves
    /// it as `serverConfig`. Uses `DeviceIdentity` for `deviceId`/`displayName` so the desktop can
    /// identify and later revoke this specific device.
    @discardableResult
    func redeemPairing(host: String, port: Int, secret: String) async -> Bool {
        let baseURLString = ServerConfig(host: host, port: port).baseURLString
        do {
            let result = try await RemoteAPIClient.redeemPairingSecret(
                baseURLString: baseURLString,
                secret: secret,
                deviceId: DeviceIdentity.deviceId,
                displayName: DeviceIdentity.displayName,
                session: urlSession
            )
            serverConfig = ServerConfig(host: host, port: port, token: result.token)
            pairingError = nil
            return true
        } catch {
            pairingError = Self.pairingErrorMessage(for: error)
            return false
        }
    }

    private static func pairingErrorMessage(for error: Error) -> String {
        switch error {
        case RemoteAPIError.server(_, let message):
            return message
        case RemoteAPIError.httpStatus(401):
            return "ペアリングコードが無効か、期限切れです。"
        default:
            return error.localizedDescription
        }
    }

    func refreshLibrary() async {
        libraryState = .loading
        do {
            let songs = try await withFailover { try await $0.fetchSongs() }
            libraryState = .loaded(songs)
            if let map = try? await withFailover({ try await $0.fetchLoudness() }) {
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
            let map = try await withFailover { try await $0.fetchLoudness() }
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
        let tempDest = downloadManager.temporaryDownloadURL(songId: song.id)
        do {
            try await withFailover { c in
                try await c.downloadFile(songId: song.id, to: tempDest, preferOriginalAudio: true) { received, total in
                    Task { @MainActor in
                        if total > 0 {
                            self.downloadProgress[song.id] = Double(received) / Double(total)
                        }
                    }
                }
            }
            try downloadManager.finalizeDownloadedPart(at: tempDest, song: song)
            downloadManager.register(song)
            await cacheArtworkAfterDownloadIfNeeded(for: song)
            await fetchAndStoreLyricsIfAvailable(for: song)
            touchDownloadLibrary()
        } catch {
            downloadError = error.localizedDescription
            try? FileManager.default.removeItem(at: tempDest)
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

    /// Downloads every track in `songs` in list order (sequential), skipping already local files.
    func downloadPlaylistSongs(_ songs: [Song]) async {
        for song in songs {
            guard !downloadManager.isDownloaded(songId: song.id) else { continue }
            await downloadSong(song)
        }
    }

    func albumHasTracksToDownload(_ album: Album) -> Bool {
        _ = downloadLibraryRevision
        return album.songs.contains { !downloadManager.isDownloaded(songId: $0.id) }
    }

    func playlistSongsContainUndownloaded(_ songs: [Song]) -> Bool {
        _ = downloadLibraryRevision
        return songs.contains { !downloadManager.isDownloaded(songId: $0.id) }
    }

    private func cacheArtworkAfterDownloadIfNeeded(for song: Song) async {
        guard !song.artworkId.isEmpty else { return }
        guard !downloadManager.hasLocalArtwork(artworkId: song.artworkId) else { return }
        do {
            let dest = downloadManager.localArtworkDestinationURL(artworkId: song.artworkId)
            try await withFailover { try await $0.downloadArtwork(artworkId: song.artworkId, to: dest) }
        } catch {
            // Optional: list rows still use remote artwork when reachable.
        }
    }

    /// Plain lyrics text if a file was saved for this track (after download or manual sync).
    func localLyricsPlainText(for songId: String) -> String? {
        lyricsFileStore.plainTextIfPresent(for: songId)
    }

    /// Lyrics for the full-screen viewer: LRC files use timed sync; `.txt` stays plain scrolling text.
    func localLyricsDisplay(for songId: String) -> LocalLyricsDisplayMode? {
        guard let raw = lyricsFileStore.plainTextIfPresent(for: songId) else { return nil }
        if lyricsFileStore.hasLRCFile(for: songId) {
            let timed = LRCParser.parseTimedLines(raw)
            if !timed.isEmpty { return .synced(timed) }
        }
        return .plain(raw)
    }

    /// Whether the user can open the lyrics screen (saved file exists).
    func hasLocalLyricsFile(for songId: String) -> Bool {
        lyricsFileStore.hasLyrics(for: songId)
    }

    private func fetchAndStoreLyricsIfAvailable(for song: Song) async {
        do {
            let payload = try await withFailover { try await $0.fetchLyrics(songId: song.id) }
            guard payload.found else { return }
            guard let type = payload.type else { return }
            guard let content = payload.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { return }
            try lyricsFileStore.saveLyrics(content, wearType: type, songId: song.id)
        } catch {
            // Lyrics are optional; do not surface as download errors.
        }
    }

    /// Fetches playlist metadata from the desktop (no local changes).
    func fetchDesktopPlaylistsPreview() async throws -> [RemoteDesktopPlaylist] {
        guard serverConfig.isConfigured else { throw DesktopPlaylistImportError.serverNotConfigured }
        return try await withFailover { try await $0.fetchDesktopPlaylists() }
    }

    /// Imports desktop playlists from `GET /v1/remote/playlists`. Requires a configured server.
    func importDesktopPlaylists(missingPolicy: DesktopPlaylistMissingPolicy) async throws -> DesktopPlaylistImportOutcome {
        guard serverConfig.isConfigured else { throw DesktopPlaylistImportError.serverNotConfigured }
        var outcome = DesktopPlaylistImportOutcome(
            playlistsCreated: 0,
            playlistsSkippedEmpty: 0,
            desktopPathsMissingFromLibrary: 0,
            tracksOmittedNotDownloaded: 0,
            failedTrackDownloads: 0
        )
        let rows = try await withFailover { try await $0.fetchDesktopPlaylists() }
        let remoteSongs = try await withFailover { try await $0.fetchSongs() }
        var remoteById: [String: Song] = [:]
        for s in remoteSongs { remoteById[s.id] = s }

        for row in rows {
            outcome.desktopPathsMissingFromLibrary += row.pathsNotInLibrary?.count ?? 0
            var idsOrdered = row.songIds

            switch missingPolicy {
            case .omitMissingDownloads:
                let before = idsOrdered.count
                idsOrdered = idsOrdered.filter { downloadManager.isDownloaded(songId: $0) }
                outcome.tracksOmittedNotDownloaded += before - idsOrdered.count
            case .downloadMissingTracks:
                for sid in row.songIds where !downloadManager.isDownloaded(songId: sid) {
                    guard let song = remoteById[sid] else {
                        outcome.failedTrackDownloads += 1
                        continue
                    }
                    await downloadSong(song)
                    if !downloadManager.isDownloaded(songId: sid) {
                        outcome.failedTrackDownloads += 1
                    }
                }
                let before = idsOrdered.count
                idsOrdered = idsOrdered.filter { downloadManager.isDownloaded(songId: $0) }
                outcome.tracksOmittedNotDownloaded += before - idsOrdered.count
            }

            guard !idsOrdered.isEmpty else {
                outcome.playlistsSkippedEmpty += 1
                continue
            }
            let name = uniquePlaylistName(desired: row.name)
            let pl = try playlistStore.createPlaylist(name: name)
            try playlistStore.addSongIds(to: pl.id, songIds: idsOrdered)
            outcome.playlistsCreated += 1
        }
        refreshPlaylists()
        return outcome
    }

    private func uniquePlaylistName(desired: String) -> String {
        let trimmed = desired.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Desktop playlist" : trimmed
        var n = 0
        while true {
            let candidate: String
            if n == 0 {
                candidate = base
            } else if n == 1 {
                candidate = "\(base) (Desktop)"
            } else {
                candidate = "\(base) (Desktop) \(n)"
            }
            let lower = candidate.lowercased()
            let clash = playlistStore.orderedPlaylists().contains { $0.name.lowercased() == lower }
            if !clash { return candidate }
            n += 1
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
        _ = downloadLibraryRevision
        return playlist.songIds.compactMap { downloadManager.downloadedSongs[$0] }
    }

    func artworkIdForPlaylist(_ playlist: Playlist) -> String {
        _ = downloadLibraryRevision
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
        _ = downloadLibraryRevision
        return favouriteSongIds.compactMap { downloadManager.downloadedSongs[$0] }
    }
}
