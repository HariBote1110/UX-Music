import Foundation
import UIKit
import WatchConnectivity

/// One song queued (or already sent) to the paired Apple Watch.
struct WatchTransferQueueItem: Identifiable {
    enum Phase: Equatable {
        case downloading
        case waiting
        /// `WatchTransferAudioPolicy` decided the local file needs transcoding to AAC before it can
        /// be sent (see `WatchTransferBridge.performTransfer`); `WatchAudioTranscoder` is running.
        case preparing
        case sending
        case sent
        case failed(String)
    }

    let id: String
    let title: String
    var phase: Phase
}

/// `WCSession` activation state, kept as a plain enum (no `WCSession` dependency) so the
/// queue/flush gating logic below is unit-testable without a real WatchConnectivity session.
enum WatchSessionActivationStatus: Equatable {
    case notActivated
    case activating
    case activated
    case failed(String)
}

/// Pure gating logic for the "activate before transferFile" bug: `WCSession.activate()` completes
/// asynchronously (`activationDidCompleteWith`), so a `send` requested beforehand must be queued
/// rather than attempted immediately — attempting it immediately is what produced the "WCSession
/// has not been activated" / "Application context data is nil" errors seen on a real device (the
/// simulator's `wcd` is lenient enough that the same call silently succeeds there).
enum WatchTransferActivationGating {
    /// Whether a `send` request should be performed immediately given the current activation status.
    static func shouldSendImmediately(status: WatchSessionActivationStatus) -> Bool {
        status == .activated
    }

    /// The bridge's new activation status once `activationDidCompleteWith` reports its result.
    static func statusAfterActivationCompletion(succeeded: Bool, errorDescription: String?) -> WatchSessionActivationStatus {
        succeeded ? .activated : .failed(errorDescription ?? "Watch connectivity activation failed")
    }
}

/// Pure phase-transition logic for `send`'s "download first, then transfer" path: a song that is
/// not downloaded yet is queued as `.downloading`, `downloadHandler` is awaited, and this decides
/// what the queue item becomes next. Kept as a free function (no `DownloadManager`/`WCSession`
/// dependency) so the download-failure branch — previously untested because `send` used to just
/// silently `return false` for undownloaded songs — is unit-testable.
enum WatchTransferDownloadOutcome {
    static func phaseAfterDownload(succeeded: Bool) -> WatchTransferQueueItem.Phase {
        succeeded ? .waiting : .failed("ダウンロードに失敗しました。デスクトップとの接続を確認してください")
    }
}

/// Pure "what actually gets transferred" decision for `performTransfer`'s transcode-then-send path
/// (`WatchTransferAudioPolicy.decision(...) == .transcode`): a successful `WatchAudioTranscoder` run
/// sends the cached AAC file, announced to the Watch as `m4a` so `meta.fileType` matches the bytes
/// actually being sent; a failed/skipped transcode falls back to the original file and its original
/// fileType, on the principle that a slow transfer of the original beats no transfer at all. Kept as
/// a free function (no `WCSession`/`WatchAudioTranscoder` dependency) so the fallback branch is
/// unit-testable without a real encoder.
enum WatchTransferTranscodeOutcome {
    struct FileToSend: Equatable {
        let url: URL
        let fileType: String
    }

    /// - Parameter transcodedURL: The cache file produced by `WatchAudioTranscoder`, or `nil` if the
    ///   transcode attempt failed.
    static func fileToSend(originalURL: URL, originalFileType: String, transcodedURL: URL?) -> FileToSend {
        guard let transcodedURL else {
            return FileToSend(url: originalURL, fileType: originalFileType)
        }
        return FileToSend(url: transcodedURL, fileType: "m4a")
    }
}

/// iOS-side WatchConnectivity bridge: sends already-downloaded audio files to the paired Apple
/// Watch via `WCSession.transferFile`, alongside a `WatchTransferMeta` metadata dictionary the
/// Watch uses to build its local library (see `WatchTransfer.swift`, shared with the Watch target).
///
/// Only locally downloaded songs can be transferred — the Watch has no server connection of its
/// own, so the audio bytes must already exist under `DownloadManager`'s tracks directory.
@MainActor
final class WatchTransferBridge: NSObject, ObservableObject {

    @Published private(set) var queue: [WatchTransferQueueItem] = []
    @Published private(set) var isPaired = false
    @Published private(set) var isWatchAppInstalled = false
    /// Observable so Settings can show *why* a transfer is stuck (e.g. still activating on launch,
    /// or activation failed) instead of the item silently sitting in `.waiting`.
    @Published private(set) var activationStatus: WatchSessionActivationStatus = .notActivated

    private let downloadManager: DownloadManager
    /// Songs requested via `send` before activation completed; flushed once `activationStatus`
    /// becomes `.activated`, or marked `.failed` if activation itself fails.
    private var pendingSongs: [Song] = []

    /// Downloads `song` from the desktop server, returning whether it is locally available
    /// afterwards. Wired up by `AppModel` after construction (see its `init`) since downloading
    /// needs `RemoteAPIClient`/`withFailover`, which this bridge deliberately has no dependency on.
    /// `send` fails a song immediately with a clear reason if this is never set.
    var downloadHandler: ((Song) async -> Bool)?

    init(downloadManager: DownloadManager) {
        self.downloadManager = downloadManager
    }

    /// Activates the `WCSession`. Must be called exactly once, as early as possible in the app's
    /// lifetime (from `AppModel.init`, not a view's `onAppear`) — on a real device `activate()`
    /// completes asynchronously, and any `send` requested in the meantime is queued by `send`
    /// below rather than attempted against a not-yet-activated session.
    func activate() {
        guard WCSession.isSupported() else {
            activationStatus = .failed("WatchConnectivity unsupported")
            return
        }
        guard activationStatus == .notActivated else { return }
        activationStatus = .activating
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Queues `song` for transfer. Songs that are not downloaded locally yet are downloaded first
    /// (shown as `.downloading` in the queue) rather than being silently dropped — this used to
    /// `return false` for undownloaded songs, which meant an undownloaded song in a bulk album
    /// transfer vanished with no queue entry and no error the user could see.
    /// If the session has not finished activating yet, the request is held in `pendingSongs` and
    /// flushed once activation completes (see `handleActivationCompletion`).
    @discardableResult
    func send(_ song: Song) -> Bool {
        guard !queue.contains(where: { $0.id == song.id && $0.phase != .sent }) else { return true }

        guard downloadManager.isDownloaded(songId: song.id) else {
            downloadThenQueue(song)
            return true
        }

        queueForTransfer(song)
        return true
    }

    /// Downloads `song` via `downloadHandler`, then queues it for transfer on success or records a
    /// `.failed` queue entry (with a reason the user can see) on failure.
    private func downloadThenQueue(_ song: Song) {
        upsert(WatchTransferQueueItem(id: song.id, title: song.displayTitle, phase: .downloading))

        guard let downloadHandler else {
            upsert(WatchTransferQueueItem(id: song.id, title: song.displayTitle, phase: .failed("ダウンロード機能が利用できません")))
            return
        }

        Task {
            let succeeded = await downloadHandler(song)
            let phase = WatchTransferDownloadOutcome.phaseAfterDownload(succeeded: succeeded)
            self.upsert(WatchTransferQueueItem(id: song.id, title: song.displayTitle, phase: phase))
            if succeeded {
                self.queueForTransfer(song)
            }
        }
    }

    /// Moves an already-downloaded `song` into `.waiting` and either transfers it immediately or
    /// holds it in `pendingSongs` until `WCSession` activation completes.
    private func queueForTransfer(_ song: Song) {
        upsert(WatchTransferQueueItem(id: song.id, title: song.displayTitle, phase: .waiting))

        guard WatchTransferActivationGating.shouldSendImmediately(status: activationStatus) else {
            pendingSongs.append(song)
            return
        }

        performTransfer(song)
    }

    /// Decides (via `WatchTransferAudioPolicy`) whether the local file needs transcoding before it
    /// can be sent, then either sends it immediately or transcodes first. Only safe to call once
    /// `activationStatus == .activated`.
    private func performTransfer(_ song: Song) {
        let localURL = URL(fileURLWithPath: downloadManager.localPathString(songId: song.id))
        let originalFileType = localURL.pathExtension.isEmpty ? song.fileType : localURL.pathExtension
        let fileSizeBytes = Self.fileSize(at: localURL)

        let decision = WatchTransferAudioPolicy.decision(
            fileType: originalFileType,
            fileSizeBytes: fileSizeBytes,
            duration: song.duration
        )

        guard decision == .transcode else {
            sendFile(localURL, fileType: originalFileType, song: song)
            return
        }

        upsert(WatchTransferQueueItem(id: song.id, title: song.displayTitle, phase: .preparing))

        let transcoder = WatchAudioTranscoder()
        Task {
            var transcodedURL: URL?
            do {
                transcodedURL = try await transcoder.transcodedFileURL(source: localURL, songId: song.id)
            } catch {
                // A slow transfer of the original file beats no transfer at all — fall through to
                // `WatchTransferTranscodeOutcome.fileToSend` below, which sends the original on `nil`.
                print("[WatchTransferBridge] Watch向けAACトランスコードに失敗、元ファイルを送信します（\(song.id)）: \(error.localizedDescription)")
            }
            let fileToSend = WatchTransferTranscodeOutcome.fileToSend(
                originalURL: localURL,
                originalFileType: originalFileType,
                transcodedURL: transcodedURL
            )
            self.sendFile(fileToSend.url, fileType: fileToSend.fileType, song: song)
        }
    }

    /// Actually calls `WCSession.transferFile` for `fileURL` (either the original local file, or a
    /// transcoded AAC cache file — see `performTransfer`), alongside a `WatchTransferMeta` built
    /// with `fileType` (which must match the bytes at `fileURL`, not necessarily `song.fileType`).
    private func sendFile(_ fileURL: URL, fileType: String, song: Song) {
        let hasArtwork = downloadManager.localArtworkFileURLIfPresent(artworkId: song.artworkId) != nil
        var meta = WatchTransferMeta(
            id: song.id,
            title: song.title,
            artist: song.artist,
            album: song.album,
            duration: song.duration,
            fileType: fileType
        )
        if hasArtwork {
            meta.artworkFileName = WatchTransferMeta.storedArtworkFileName(forId: song.id)
        }

        upsert(WatchTransferQueueItem(id: song.id, title: song.displayTitle, phase: .sending))

        guard WCSession.isSupported() else {
            upsert(WatchTransferQueueItem(id: song.id, title: song.displayTitle, phase: .failed("WatchConnectivity unsupported")))
            return
        }
        let session = WCSession.default
        guard session.activationState == .activated else {
            upsert(WatchTransferQueueItem(id: song.id, title: song.displayTitle, phase: .failed("Watch not connected")))
            return
        }

        session.transferFile(fileURL, metadata: meta.wcMetadata)

        // Artwork is sent as its own `transferFile` rather than embedded in `meta.wcMetadata`
        // (WatchConnectivity metadata dictionaries are meant for small key/value pairs, not image
        // bytes) — downscaled here so the transfer stays small and quick over Bluetooth/Wi-Fi.
        if let artworkURL = downloadManager.localArtworkFileURLIfPresent(artworkId: song.artworkId),
           let downscaledURL = Self.writeDownscaledArtwork(from: artworkURL, songId: song.id) {
            session.transferFile(downscaledURL, metadata: meta.artworkWcMetadata)
        }

        upsert(WatchTransferQueueItem(id: song.id, title: song.displayTitle, phase: .sent))
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Downscales the artwork at `sourceURL` to a long edge of ~400px and re-encodes it as a JPEG
    /// (~50KB target) into a temporary file, suitable for the small Watch screen and a quick
    /// WatchConnectivity transfer. Returns `nil` if the source image cannot be decoded.
    private static func writeDownscaledArtwork(from sourceURL: URL, songId: String) -> URL? {
        guard let image = UIImage(contentsOfFile: sourceURL.path) else { return nil }
        let maxDimension: CGFloat = 400
        let longEdge = max(image.size.width, image.size.height)
        let scale = longEdge > maxDimension ? maxDimension / longEdge : 1
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let jpegData = resized.jpegData(compressionQuality: 0.6) else { return nil }

        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(WatchTransferMeta.storedArtworkFileName(forId: songId))
        try? FileManager.default.removeItem(at: destURL)
        do {
            try jpegData.write(to: destURL)
            return destURL
        } catch {
            return nil
        }
    }

    private func handleActivationCompletion(succeeded: Bool, errorDescription: String?) {
        activationStatus = WatchTransferActivationGating.statusAfterActivationCompletion(
            succeeded: succeeded,
            errorDescription: errorDescription
        )
        refreshPairingState()

        let songs = pendingSongs
        pendingSongs.removeAll()
        switch activationStatus {
        case .activated:
            songs.forEach { performTransfer($0) }
        case .failed(let reason):
            songs.forEach { upsert(WatchTransferQueueItem(id: $0.id, title: $0.displayTitle, phase: .failed(reason))) }
        case .notActivated, .activating:
            // Should not happen (handleActivationCompletion only runs after activate() reports),
            // but re-queue defensively rather than dropping the request.
            pendingSongs = songs
        }
    }

    private func upsert(_ item: WatchTransferQueueItem) {
        if let index = queue.firstIndex(where: { $0.id == item.id }) {
            queue[index] = item
        } else {
            queue.append(item)
        }
    }

    private func refreshPairingState() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
    }
}

// MARK: - WCSessionDelegate

extension WatchTransferBridge: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor in
            handleActivationCompletion(succeeded: activationState == .activated, errorDescription: error?.localizedDescription)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in refreshPairingState() }
    }

    nonisolated func session(
        _ session: WCSession,
        didFinish fileTransfer: WCSessionFileTransfer,
        error: Error?
    ) {
        guard let songId = fileTransfer.file.metadata?[WatchTransferMeta.metadataIDKey] as? String else { return }
        Task { @MainActor in
            if let error {
                self.upsert(WatchTransferQueueItem(id: songId, title: "", phase: .failed(error.localizedDescription)))
            }
        }
    }
}
