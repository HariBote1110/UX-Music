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

/// How to render on-device lyrics *with* their Japanese translation (和訳) merged in — an
/// additive counterpart to `LocalLyricsDisplayMode` kept as a separate type/API
/// (`AppModel.localBilingualLyricsDisplay(for:)`) rather than changing that enum's associated
/// values, so `Views/NowPlayingLyricsScreen.swift`'s existing `.plain(String)`/`.synced([LRCParser
/// .TimedLine])` switch keeps compiling unchanged. The View agent can adopt this new API when
/// building the 和訳 UI.
enum BilingualLyricsDisplayMode: Equatable {
    case plain([TranslatedPlainLine])
    case synced([TranslatedTimedLine])
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

    /// User-selected local Library sort order, persisted to `UserDefaults` so it survives relaunch.
    var librarySortOrder: LibrarySortOrder {
        didSet {
            guard librarySortOrder != oldValue else { return }
            UserDefaults.standard.set(librarySortOrder.rawValue, forKey: AppConstants.librarySortOrderKey)
        }
    }

    /// User-selected local Library album grid sort order, persisted to `UserDefaults` so it survives relaunch.
    var albumSortOrder: AlbumSortOrder {
        didSet {
            guard albumSortOrder != oldValue else { return }
            UserDefaults.standard.set(albumSortOrder.rawValue, forKey: AppConstants.albumSortOrderKey)
        }
    }

    /// User-selected local Library artist list sort order, persisted to `UserDefaults` so it survives relaunch.
    var artistSortOrder: ArtistSortOrder {
        didSet {
            guard artistSortOrder != oldValue else { return }
            UserDefaults.standard.set(artistSortOrder.rawValue, forKey: AppConstants.artistSortOrderKey)
        }
    }

    /// User-selected audio quality for new downloads (Settings → ダウンロード音質), persisted to
    /// `UserDefaults` so it survives relaunch. Only affects downloads requested after the change —
    /// see `downloadSong` and `progress/download-audio-quality.md`.
    var downloadAudioQuality: DownloadAudioQuality {
        didSet {
            guard downloadAudioQuality != oldValue else { return }
            UserDefaults.standard.set(downloadAudioQuality.rawValue, forKey: AppConstants.downloadAudioQualityKey)
        }
    }

    /// "For You" server-generated playlists (`GET /v1/remote/situation-playlists`), loaded on
    /// demand via `refreshSituationPlaylists()`. Empty (not an error state) when the desktop
    /// predates the endpoint (404) or hasn't been queried yet.
    private(set) var situationPlaylists: [SituationPlaylist] = []

    /// Message from the most recent failed `redeemPairing` call (invalid/expired secret, unreachable
    /// host, …), shown by Settings next to the pairing field.
    var pairingError: String?

    /// Drives the full-screen now playing sheet (lives on `AppModel` so `tabViewBottomAccessory` can update presentation reliably).
    var isNowPlayingSheetPresented = false

    /// Debug-only hook (set via `UXM_DEBUG_LYRICS_SONG`, see `UXMusicMobileApp`) asking
    /// `NowPlayingView` to auto-open its synced-lyrics screen once presented, so the lyrics
    /// motion can be recorded/inspected without driving the tap-through UI by hand.
    var debugForceOpenLyrics = false

    /// songId → 0...1 while downloading
    var downloadProgress: [String: Double] = [:]
    /// Last failure from `downloadSong` / `downloadAlbum` (shown on Remote Library).
    var downloadError: String?

    /// Bumped when local download metadata changes so `@Observable` invalidates library views that do not read `downloadProgress`.
    private(set) var downloadLibraryRevision: Int = 0

    let downloadManager: DownloadManager
    /// Metadata-only membership for songs with no local file (YouTube songs added via "ライブラリに追加").
    let libraryMembershipStore: LibraryMembershipStore
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
        if let raw = UserDefaults.standard.string(forKey: AppConstants.librarySortOrderKey),
           let restored = LibrarySortOrder(rawValue: raw) {
            librarySortOrder = restored
        } else {
            librarySortOrder = .album
        }
        if let raw = UserDefaults.standard.string(forKey: AppConstants.albumSortOrderKey),
           let restored = AlbumSortOrder(rawValue: raw) {
            albumSortOrder = restored
        } else {
            albumSortOrder = .name
        }
        if let raw = UserDefaults.standard.string(forKey: AppConstants.artistSortOrderKey),
           let restored = ArtistSortOrder(rawValue: raw) {
            artistSortOrder = restored
        } else {
            artistSortOrder = .name
        }
        downloadAudioQuality = DownloadAudioQuality.restored(
            fromRawValue: UserDefaults.standard.string(forKey: AppConstants.downloadAudioQualityKey)
        )
        downloadManager = DownloadManager()
        libraryMembershipStore = LibraryMembershipStore()
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
        player.resolveYouTubeVideoID = { [weak self] song in
            guard let self else { return nil }
            let url = song.sourceURL ?? song.path
            return try? await self.withFailover { try await $0.resolveYouTubeVideo(url: url).videoId }
        }
        refreshPlaylists()
        // Wired up after every stored property is initialised (not passed into
        // WatchTransferBridge's own initialiser) because downloading needs `withFailover`/
        // `RemoteAPIClient`, which live on `AppModel` itself — giving the bridge a closure avoids a
        // circular dependency between the two types.
        watchTransferBridge.downloadHandler = { [weak self] song in
            guard let self else { return false }
            await self.downloadSong(song)
            return self.downloadManager.isDownloaded(songId: song.id)
        }
    }

    private func touchDownloadLibrary() {
        downloadLibraryRevision &+= 1
    }

    /// Every song that is a member of the local Library: downloaded files, plus YouTube songs
    /// added via "ライブラリに追加" (no local file — see `LibraryMembershipStore`). Downloaded
    /// metadata wins on an id clash, though the two sets do not overlap in practice.
    private var librarySongsById: [String: Song] {
        _ = downloadLibraryRevision
        var byId = libraryMembershipStore.songs
        for (id, song) in downloadManager.downloadedSongs { byId[id] = song }
        return byId
    }

    /// Local Library tracks in album / disc / track order (not global title sort — avoids scrambled queues and grids).
    var sortedDownloadedSongsForLibrary: [Song] {
        librarySongsById.values.sorted(by: Song.libraryFlatDisplayOrderAscending)
    }

    func isSongDownloaded(songId: String) -> Bool {
        _ = downloadLibraryRevision
        return downloadManager.isDownloaded(songId: songId)
    }

    /// Whether `songId` belongs to the local Library at all — a downloaded file, or a YouTube
    /// song added via "ライブラリに追加". Unlike `isSongDownloaded`, true for YouTube members
    /// even though they have no local file.
    func isLibrarySongMember(songId: String) -> Bool {
        _ = downloadLibraryRevision
        return libraryMembershipStore.contains(songId: songId) || downloadManager.isDownloaded(songId: songId)
    }

    /// Adds a YouTube song (`song.isYouTube == true`) to the local Library as metadata only —
    /// no file download, no Watch transfer (see `WatchTransferMenuPolicy`).
    func addYouTubeSongToLibrary(_ song: Song) {
        guard song.isYouTube else { return }
        libraryMembershipStore.add(song)
        touchDownloadLibrary()
    }

    func removeYouTubeSongFromLibrary(songId: String) {
        favouriteSongStore.remove(songId: songId)
        favouriteSongIds = favouriteSongStore.orderedIds
        libraryMembershipStore.remove(songId: songId)
        touchDownloadLibrary()
    }

    /// Removes a Library song regardless of kind — a downloaded file or a YouTube membership.
    func removeDownloadedSong(songId: String) {
        if libraryMembershipStore.contains(songId: songId) {
            removeYouTubeSongFromLibrary(songId: songId)
            return
        }
        lyricsFileStore.remove(for: songId)
        downloadManager.remove(songId: songId)
        touchDownloadLibrary()
    }

    /// Library songs not already in the playlist (for “Add songs”); observes `downloadLibraryRevision`.
    func downloadedSongsEligibleForPlaylist(excludingPlaylistSongIds songIds: Set<String>) -> [Song] {
        librarySongsById.values
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
        let hostsToTry = ConnectionCandidatePolicy.hostsToTry(
            primaryHost: serverConfig.host,
            fallbackHosts: serverConfig.fallbackHosts,
            preferredHost: serverConfig.preferredHost
        )

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

    /// Applies a pairing URL from QR or deep link: probes every LAN address the desktop advertised
    /// (`hosts=`) for reachability, then redeems the embedded one-time secret against whichever
    /// candidate answered, mirroring the mDNS-discovery failover in `RemoteConnectionResolver`.
    /// Returns whether pairing succeeded; on any failure — malformed URL, no reachable host, or a
    /// rejected secret — `pairingError` is set to a user-facing message rather than failing silently.
    @discardableResult
    func applyPairingURL(_ url: URL) async -> Bool {
        guard let request = ServerConfig.pairingRequest(fromPairingURL: url) else {
            pairingError = "QRコードを読み取れませんでした。デスクトップアプリを最新版に更新してください。"
            return false
        }
        return await redeemPairing(hosts: request.hosts, port: request.port, secret: request.secret)
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

    /// Probes `hosts` in order (like `withFailover`/Discovery) for the first one that answers
    /// `GET /v1/identity`, then redeems the secret against that reachable host. On success, the
    /// remaining candidates are kept as `fallbackHosts` so later requests can fail over too.
    @discardableResult
    func redeemPairing(hosts: [String], port: Int, secret: String) async -> Bool {
        let candidates = hosts.map { ServerConfig(host: $0, port: port) }
        let resolved = await RemoteConnectionResolver.resolve(candidates: candidates) { candidate in
            try await RemoteAPIClient(baseURLString: candidate.baseURLString, session: urlSession).ping()
        }
        guard let resolved else {
            pairingError = "デスクトップに到達できません。同じ Wi-Fi に接続しているか確認してください。"
            return false
        }
        let ok = await redeemPairing(host: resolved.config.host, port: port, secret: secret)
        if ok {
            serverConfig.fallbackHosts = hosts.filter { $0 != resolved.config.host }
        }
        return ok
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

    /// Downloads `song` according to `downloadAudioQuality`: one request for `.original`/`.aac`,
    /// two sequential requests for `.both` (original, then AAC — see `DownloadRequestPlan`), sharing
    /// a single `downloadProgress[song.id]` entry mapped 0–1 across whichever steps run. The song is
    /// registered once its first step succeeds; if `.both`'s second (AAC) step then fails, the error
    /// is surfaced via `downloadError` but the already-downloaded first file stays registered.
    func downloadSong(_ song: Song) async {
        guard downloadProgress[song.id] == nil else { return }
        downloadError = nil
        downloadProgress[song.id] = 0
        let steps = DownloadRequestPlan.steps(for: downloadAudioQuality)
        var registered = false

        for (index, step) in steps.enumerated() {
            let tempDest = downloadManager.temporaryDownloadURL(songId: song.id)
            let stepBase = Double(index) / Double(steps.count)
            let stepSpan = 1.0 / Double(steps.count)
            do {
                try await withFailover { c in
                    try await c.downloadFile(songId: song.id, to: tempDest, preferOriginalAudio: step.preferOriginalAudio) { received, total in
                        Task { @MainActor in
                            if total > 0 {
                                self.downloadProgress[song.id] = stepBase + stepSpan * (Double(received) / Double(total))
                            }
                        }
                    }
                }
                if step.preferOriginalAudio {
                    try downloadManager.finalizeDownloadedPart(at: tempDest, song: song)
                } else {
                    try downloadManager.finalizeDownloadedAACPart(at: tempDest, song: song)
                }
                if !registered {
                    downloadManager.register(song)
                    registered = true
                }
            } catch {
                try? FileManager.default.removeItem(at: tempDest)
                downloadError = error.localizedDescription
                guard registered else {
                    // First step failed: nothing was downloaded, matching the previous single-request behaviour.
                    downloadProgress.removeValue(forKey: song.id)
                    return
                }
                // `.both`'s second (AAC) step failed after the first succeeded: keep the first file.
                break
            }
        }

        await cacheArtworkAfterDownloadIfNeeded(for: song)
        await fetchAndStoreLyricsIfAvailable(for: song)
        touchDownloadLibrary()
        downloadProgress.removeValue(forKey: song.id)
    }

    /// Downloads every track in `album` that is not already local, in album order (sequential).
    /// YouTube entries have no downloadable file on the desktop side and are skipped.
    func downloadAlbum(_ album: Album) async {
        for song in album.songs where !song.isYouTube {
            guard !downloadManager.isDownloaded(songId: song.id) else { continue }
            await downloadSong(song)
        }
    }

    /// Downloads every track in `songs` in list order (sequential), skipping already local files
    /// and YouTube entries (see `downloadAlbum`).
    func downloadPlaylistSongs(_ songs: [Song]) async {
        for song in songs where !song.isYouTube {
            guard !downloadManager.isDownloaded(songId: song.id) else { continue }
            await downloadSong(song)
        }
    }

    func albumHasTracksToDownload(_ album: Album) -> Bool {
        _ = downloadLibraryRevision
        return album.songs.contains { !$0.isYouTube && !downloadManager.isDownloaded(songId: $0.id) }
    }

    func playlistSongsContainUndownloaded(_ songs: [Song]) -> Bool {
        _ = downloadLibraryRevision
        return songs.contains { !$0.isYouTube && !downloadManager.isDownloaded(songId: $0.id) }
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

    /// Lyrics for the full-screen viewer, merged with the Japanese translation sidecar when one was
    /// saved (see `LyricsTranslationMerger`). `nil` when no local lyrics file exists at all.
    func localBilingualLyricsDisplay(for songId: String) -> BilingualLyricsDisplayMode? {
        guard let raw = lyricsFileStore.plainTextIfPresent(for: songId) else { return nil }
        let translationRaw = lyricsFileStore.translationPlainTextIfPresent(for: songId)

        guard lyricsFileStore.hasLRCFile(for: songId) else {
            return .plain(LyricsTranslationMerger.mergePlainWithJaTxt(primaryText: raw, translationText: translationRaw ?? ""))
        }
        let timed = LRCParser.parseTimedLines(raw)
        guard !timed.isEmpty else {
            return .plain(LyricsTranslationMerger.mergePlainWithJaTxt(primaryText: raw, translationText: translationRaw ?? ""))
        }
        guard let translationRaw else {
            return .synced(timed.map { TranslatedTimedLine(id: $0.id, startTime: $0.startTime, text: $0.text, translation: nil) })
        }
        if lyricsFileStore.hasJaLRCFile(for: songId) {
            let translationTimed = LRCParser.parseTimedLines(translationRaw)
            return .synced(LyricsTranslationMerger.mergeTimedWithJaLRC(primary: timed, translation: translationTimed))
        }
        return .synced(LyricsTranslationMerger.mergeTimedWithJaTxt(primary: timed, translationText: translationRaw))
    }

    private func fetchAndStoreLyricsIfAvailable(for song: Song) async {
        do {
            let payload = try await withFailover { try await $0.fetchLyrics(songId: song.id) }
            guard payload.found else { return }
            guard let type = payload.type else { return }
            guard let content = payload.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { return }
            try lyricsFileStore.saveLyrics(content, wearType: type, songId: song.id)
            if let translationFormat = payload.translationFormat,
               let translationContent = payload.translationContent?.trimmingCharacters(in: .whitespacesAndNewlines),
               !translationContent.isEmpty {
                try? lyricsFileStore.saveTranslation(translationContent, translationFormat: translationFormat, songId: song.id)
            }
        } catch {
            // Lyrics are optional; do not surface as download errors.
        }
    }

    // MARK: - For You (situation playlists)

    /// Loads `GET /v1/remote/situation-playlists` on demand. On a 404 (desktop predates the
    /// endpoint) resolves to an empty list rather than surfacing an error — this is a graceful
    /// "feature not available yet" outcome, not a failure. Other errors leave the previous
    /// `situationPlaylists` value in place (matching `refreshLoudnessOnly`'s failure handling).
    func refreshSituationPlaylists() async {
        do {
            situationPlaylists = try await withFailover { try await $0.fetchSituationPlaylists() }
        } catch RemoteAPIError.httpStatus(404) {
            situationPlaylists = []
        } catch {
            // Keep the previous value; the desktop may just be briefly unreachable.
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

    /// Maps `playlist.songIds` to Library `Song`s (downloaded or YouTube members); missing IDs
    /// are skipped (removed tracks).
    func resolvedSongs(for playlist: Playlist) -> [Song] {
        let byId = librarySongsById
        return playlist.songIds.compactMap { byId[$0] }
    }

    func artworkIdForPlaylist(_ playlist: Playlist) -> String {
        let byId = librarySongsById
        for sid in playlist.songIds {
            if let s = byId[sid], !s.artworkId.isEmpty {
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

    /// Favourite ids mapped to Library `Song`s (downloaded or YouTube members; missing entries omitted).
    func favouriteSongsForPlayback() -> [Song] {
        let byId = librarySongsById
        return favouriteSongIds.compactMap { byId[$0] }
    }
}
