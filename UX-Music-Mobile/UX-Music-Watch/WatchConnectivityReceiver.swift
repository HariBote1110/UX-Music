import Foundation
import WatchConnectivity

/// Receives audio files sent from the paired iPhone (`WatchTransferBridge.send`) and hands them off
/// to `WatchLocalLibrary` once the file has been moved out of WatchConnectivity's transient inbox.
@MainActor
final class WatchConnectivityReceiver: NSObject, ObservableObject {

    @Published var isReceiving = false
    @Published var receivingTitle = ""

    private let library: WatchLocalLibrary

    init(library: WatchLocalLibrary) {
        self.library = library
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityReceiver: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let meta = WatchTransferMeta.fromWCMetadata(file.metadata) else {
            print("[WatchConnectivityReceiver] Received file without valid metadata")
            return
        }

        Task { @MainActor in
            isReceiving = true
            receivingTitle = meta.displayTitle

            let dest = library.audioFileURL(for: meta)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: file.fileURL, to: dest)
                library.addSong(meta)
            } catch {
                print("[WatchConnectivityReceiver] Failed to save file: \(error)")
            }

            isReceiving = false
            receivingTitle = ""
        }
    }
}
