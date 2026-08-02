import Foundation
import WatchConnectivity

/// One song queued (or already sent) to the paired Apple Watch.
struct WatchTransferQueueItem: Identifiable {
    enum Phase: Equatable {
        case waiting
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

    /// Queues `song` for transfer. Requires the song be downloaded locally; no-ops otherwise.
    /// If the session has not finished activating yet, the request is held in `pendingSongs` and
    /// flushed once activation completes (see `handleActivationCompletion`).
    @discardableResult
    func send(_ song: Song) -> Bool {
        guard downloadManager.isDownloaded(songId: song.id) else { return false }
        guard !queue.contains(where: { $0.id == song.id && $0.phase != .sent }) else { return true }

        upsert(WatchTransferQueueItem(id: song.id, title: song.displayTitle, phase: .waiting))

        guard WatchTransferActivationGating.shouldSendImmediately(status: activationStatus) else {
            pendingSongs.append(song)
            return true
        }

        performTransfer(song)
        return true
    }

    /// Actually calls `WCSession.transferFile`. Only safe to call once `activationStatus == .activated`.
    private func performTransfer(_ song: Song) {
        let localURL = URL(fileURLWithPath: downloadManager.localPathString(songId: song.id))
        let meta = WatchTransferMeta(
            id: song.id,
            title: song.title,
            artist: song.artist,
            album: song.album,
            duration: song.duration,
            fileType: (localURL.pathExtension.isEmpty ? song.fileType : localURL.pathExtension)
        )

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

        session.transferFile(localURL, metadata: meta.wcMetadata)
        upsert(WatchTransferQueueItem(id: song.id, title: song.displayTitle, phase: .sent))
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
