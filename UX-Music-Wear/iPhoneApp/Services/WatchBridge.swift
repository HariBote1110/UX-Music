import Foundation
import WatchConnectivity

// MARK: - TransferItem

enum TransferPhase {
    case waiting
    case downloading(Double)
    case sending
    case failed(String)
}

struct TransferItem: Identifiable {
    let id = UUID()
    let song: Song
    var phase: TransferPhase = .waiting
}

// MARK: - WatchBridge

@MainActor
final class WatchBridge: NSObject, ObservableObject {

    @Published var queue: [TransferItem] = []
    @Published var completed: [TransferItem] = []

    private var isProcessing = false

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func enqueue(_ song: Song) {
        guard !queue.contains(where: { $0.song.id == song.id }) else { return }
        queue.append(TransferItem(song: song))
        processQueueIfNeeded()
    }

    func enqueueAll(_ songs: [Song]) {
        for song in songs { enqueue(song) }
    }

    func cancelAll() {
        queue.removeAll()
    }

    // MARK: - Internal

    private func processQueueIfNeeded() {
        guard !isProcessing, let index = queue.firstIndex(where: {
            if case .waiting = $0.phase { return true }
            return false
        }) else { return }

        isProcessing = true
        Task { await processItem(at: index) }
    }

    private func processItem(at index: Int) async {
        guard index < queue.count else { isProcessing = false; return }

        let song = queue[index].song
        let settings = WearSettings.load()
        guard let baseURL = settings.baseURL else {
            queue[index].phase = .failed("Server not configured")
            advance()
            return
        }

        let client = MusicServerClient(baseURL: baseURL)

        // 1. Download from Mac
        queue[index].phase = .downloading(0)
        let localURL: URL
        do {
            localURL = try await client.downloadFile(songID: song.id)
            queue[index].phase = .sending
        } catch {
            queue[index].phase = .failed(error.localizedDescription)
            advance()
            return
        }

        // 2. Send to Watch
        let meta: [String: Any] = [
            "id": song.id,
            "title": song.displayTitle,
            "artist": song.displayArtist,
            "album": song.displayAlbum,
            "duration": song.duration,
            "fileType": song.fileType
        ]
        let session = WCSession.default
        guard session.activationState == .activated, session.isWatchAppInstalled else {
            queue[index].phase = .failed("Watch not reachable")
            advance()
            return
        }

        let destName = "\(song.id).\(song.fileType)"
        let destURL = FileManager.default.temporaryDirectory.appendingPathComponent(destName)
        try? FileManager.default.removeItem(at: destURL)
        do {
            try FileManager.default.moveItem(at: localURL, to: destURL)
        } catch {
            queue[index].phase = .failed("File move failed: \(error.localizedDescription)")
            advance()
            return
        }

        session.transferFile(destURL, metadata: meta)

        let finished = queue[index]
        queue.remove(at: index)
        completed.append(finished)
        advance()
    }

    private func advance() {
        isProcessing = false
        processQueueIfNeeded()
    }
}

// MARK: - WCSessionDelegate

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
