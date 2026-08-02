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

    private let downloadManager: DownloadManager

    init(downloadManager: DownloadManager) {
        self.downloadManager = downloadManager
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        refreshPairingState()
    }

    /// Queues `song` for transfer. Requires the song be downloaded locally; no-ops otherwise.
    @discardableResult
    func send(_ song: Song) -> Bool {
        guard downloadManager.isDownloaded(songId: song.id) else { return false }
        guard !queue.contains(where: { $0.id == song.id && $0.phase != .sent }) else { return true }

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
            return false
        }
        let session = WCSession.default
        guard session.activationState == .activated else {
            upsert(WatchTransferQueueItem(id: song.id, title: song.displayTitle, phase: .failed("Watch not connected")))
            return false
        }

        session.transferFile(localURL, metadata: meta.wcMetadata)
        upsert(WatchTransferQueueItem(id: song.id, title: song.displayTitle, phase: .sent))
        return true
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
        Task { @MainActor in refreshPairingState() }
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
