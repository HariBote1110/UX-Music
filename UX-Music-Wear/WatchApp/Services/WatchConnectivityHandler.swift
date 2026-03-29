import Foundation
import WatchConnectivity

@MainActor
final class WatchConnectivityHandler: NSObject, ObservableObject {

    @Published var isReceiving = false
    @Published var receivingTitle = ""

    var onFileReceived: ((WatchSongMeta, URL) -> Void)?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityHandler: WCSessionDelegate {

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        print("[WatchConnectivity] Activated: \(activationState.rawValue)")
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard
            let id = file.metadata?["id"] as? String,
            let title = file.metadata?["title"] as? String,
            let artist = file.metadata?["artist"] as? String,
            let album = file.metadata?["album"] as? String,
            let duration = file.metadata?["duration"] as? Double,
            let fileType = file.metadata?["fileType"] as? String
        else {
            print("[WatchConnectivity] Received file without expected metadata")
            return
        }

        Task { @MainActor in
            isReceiving = true
            receivingTitle = title
        }

        // Move from temp to Documents
        let dest = LocalLibrary.documentsDirectory.appendingPathComponent("\(id).\(fileType)")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: file.fileURL, to: dest)
        } catch {
            print("[WatchConnectivity] Failed to save file: \(error)")
            Task { @MainActor in isReceiving = false }
            return
        }

        let meta = WatchSongMeta(
            id: id,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            fileType: fileType
        )

        Task { @MainActor in
            onFileReceived?(meta, dest)
            isReceiving = false
            receivingTitle = ""
        }
    }
}

// MARK: - WatchSongMeta

/// Lightweight song metadata sent via WatchConnectivity (no full Song struct needed)
struct WatchSongMeta: Codable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let fileType: String
}
