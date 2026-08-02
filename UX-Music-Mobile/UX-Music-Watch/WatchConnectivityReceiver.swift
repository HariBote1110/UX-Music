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

        // `file.fileURL` is only guaranteed valid for the duration of this delegate call — moving
        // it must happen synchronously, right here, on whatever (background) thread WatchConnectivity
        // invoked us on. The previous implementation hopped to `@MainActor` via `Task` *before*
        // touching the file, so by the time the copy ran the system had often already deleted the
        // transient inbox file: the copy silently failed and the song never reached the library,
        // which is why received songs never appeared on the Watch. `WatchAudioStorage` is a plain
        // (non-actor-isolated) enum precisely so this path can resolve the destination and copy
        // without waiting for the main actor.
        let dest = WatchAudioStorage.audioFileURL(for: meta)
        try? FileManager.default.removeItem(at: dest)
        let result: WatchFileReceiveResult
        do {
            try FileManager.default.copyItem(at: file.fileURL, to: dest)
            result = .succeeded(meta)
        } catch {
            print("[WatchConnectivityReceiver] Failed to save file: \(error)")
            result = .failed(error.localizedDescription)
        }

        Task { @MainActor in
            isReceiving = true
            receivingTitle = meta.displayTitle

            if WatchFileReceiveHandling.shouldAddToLibrary(result) {
                library.addSong(meta)
            }

            isReceiving = false
            receivingTitle = ""
        }
    }
}
