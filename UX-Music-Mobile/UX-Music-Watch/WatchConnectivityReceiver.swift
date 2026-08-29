import Foundation
import WatchConnectivity

/// Receives audio files sent from the paired iPhone (`WatchTransferBridge.send`) and hands them off
/// to `WatchLocalLibrary` once the file has been moved out of WatchConnectivity's transient inbox.
///
/// **Playlists**: also receives an optional `transferFile` tagged `metadata["kind"] == "playlists"`
/// (mirroring how artwork is tagged `kind: "artwork"` — see the `isArtworkWcMetadata` check below),
/// whose file contents are a JSON-encoded `[WatchPlaylistMeta]` array, handed to
/// `WatchPlaylistLibrary.replaceAll(_:)`. **This half of the pipe is Watch-side only**: nothing on
/// the iPhone sends such a transfer yet. `WatchTransferBridge` (`UX-Music-Mobile/Services/
/// WatchTransferBridge.swift`, outside this target's ownership) would need a new method that reads
/// `PlaylistStore`'s playlists, maps each to `WatchPlaylistMeta(id: playlist.id, name: playlist.name,
/// songIds: playlist.songIds)`, JSON-encodes the array to a temp file, and calls
/// `WCSession.default.transferFile(tempURL, metadata: ["id": "playlists", "kind": "playlists"])` —
/// analogous to the existing artwork `transferFile` call, just with the whole array as one file
/// instead of one file per song.
@MainActor
final class WatchConnectivityReceiver: NSObject, ObservableObject {

    @Published var isReceiving = false
    @Published var receivingTitle = ""

    private let library: WatchLocalLibrary
    private let playlistLibrary: WatchPlaylistLibrary

    init(library: WatchLocalLibrary, playlistLibrary: WatchPlaylistLibrary) {
        self.library = library
        self.playlistLibrary = playlistLibrary
    }

    /// Tag used on the playlists `transferFile`'s metadata dictionary, alongside
    /// `WatchTransferMeta.metadataKindKey` — kept here (not on `WatchTransferMeta`, which this
    /// target does not own) since the playlist transfer is Watch-side-only for now; see the
    /// type-level doc comment for what the iOS sender still needs to send to make use of it.
    static let kindPlaylists = "playlists"

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
        // Artwork arrives as its own `transferFile`, tagged with `kind: "artwork"` rather than the
        // full song metadata `fromWCMetadata` expects — handle it separately and return before
        // attempting (and failing) to parse it as a song.
        if WatchTransferMeta.isArtworkWcMetadata(file.metadata) {
            guard let id = file.metadata?[WatchTransferMeta.metadataIDKey] as? String else { return }
            let dest = WatchAudioStorage.artworkFileURL(forId: id)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: file.fileURL, to: dest)
            return
        }

        // Playlists likewise arrive as their own `transferFile` — see the type-level doc comment.
        // `file.fileURL` must be read synchronously here (before returning to WatchConnectivity),
        // same constraint as the audio-file copy below.
        if file.metadata?[WatchTransferMeta.metadataKindKey] as? String == Self.kindPlaylists {
            guard
                let data = try? Data(contentsOf: file.fileURL),
                let decoded = try? JSONDecoder().decode([WatchPlaylistMeta].self, from: data)
            else { return }
            Task { @MainActor in
                playlistLibrary.replaceAll(decoded)
            }
            return
        }

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
