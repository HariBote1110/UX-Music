import Foundation

/// Lightweight song metadata transferred between iPhone and Apple Watch over WatchConnectivity.
/// Kept separate from the full `Song` model so the `transferFile` payload stays small and the
/// Watch app does not need the desktop-facing fields (path, artworkId, etc.).
///
/// This type has iOS and watchOS target membership: it is the shared contract between
/// `WatchTransferBridge` (iOS sender) and the watchOS receiver/library.
struct WatchTransferMeta: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var fileType: String
    /// Filename of a downscaled artwork JPEG, transferred as a *separate* `transferFile` (not
    /// embedded in this metadata dictionary — WatchConnectivity metadata has a small size limit
    /// unsuited to image bytes). `nil` when the song has no locally-cached artwork on the iPhone at
    /// send time, or for songs transferred before artwork support existed (re-sending fills it in).
    var artworkFileName: String? = nil
    /// 1-based track/disc number from `Song.trackNumber`/`Song.discNumber`, `nil` when the source
    /// tag is missing (`Song`'s fields default to `0` for "unknown" — see `WatchTransferBridge`,
    /// which maps that to `nil` here). Used by `WatchAlbumGrouping` to sort an album's songs into
    /// their proper track order instead of assuming transfer order == track order — an assumption
    /// broken by on-device transcoding, which can complete (and therefore `transferFile`) out of
    /// enqueue order. Optional so old persisted Watch index JSON, and metadata from a sender that
    /// predates these fields, still decode/parse fine.
    var trackNumber: Int? = nil
    var discNumber: Int? = nil

    var displayTitle: String { title.isEmpty ? "Unknown Title" : title }
    var displayArtist: String { artist.isEmpty ? "Unknown Artist" : artist }
    var displayAlbum: String { album.isEmpty ? "Unknown Album" : album }

    var formattedDuration: String {
        let total = Int(duration)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static let metadataIDKey = "id"
    static let metadataTitleKey = "title"
    static let metadataArtistKey = "artist"
    static let metadataAlbumKey = "album"
    static let metadataDurationKey = "duration"
    static let metadataFileTypeKey = "fileType"
    static let metadataArtworkFileNameKey = "artworkFileName"
    static let metadataTrackNumberKey = "trackNumber"
    static let metadataDiscNumberKey = "discNumber"
    /// Distinguishes an artwork-only `transferFile` (see `kindArtwork`) from a regular audio
    /// transfer, since the two carry very different metadata shapes.
    static let metadataKindKey = "kind"
    static let kindArtwork = "artwork"

    /// Dictionary shape expected by `WCSession.transferFile(_:metadata:)`.
    var wcMetadata: [String: Any] {
        var dict: [String: Any] = [
            Self.metadataIDKey: id,
            Self.metadataTitleKey: title,
            Self.metadataArtistKey: artist,
            Self.metadataAlbumKey: album,
            Self.metadataDurationKey: duration,
            Self.metadataFileTypeKey: fileType
        ]
        if let artworkFileName {
            dict[Self.metadataArtworkFileNameKey] = artworkFileName
        }
        if let trackNumber {
            dict[Self.metadataTrackNumberKey] = trackNumber
        }
        if let discNumber {
            dict[Self.metadataDiscNumberKey] = discNumber
        }
        return dict
    }

    /// Metadata dictionary for the separate artwork `transferFile` (see `storedArtworkFileName`).
    var artworkWcMetadata: [String: Any] {
        [Self.metadataIDKey: id, Self.metadataKindKey: Self.kindArtwork]
    }

    /// Parses a WatchConnectivity file-transfer metadata dictionary; `nil` if a required key is
    /// missing or has the wrong type (defends against a stale sender / receiver version mismatch).
    static func fromWCMetadata(_ metadata: [String: Any]?) -> WatchTransferMeta? {
        guard
            let id = metadata?[metadataIDKey] as? String,
            let title = metadata?[metadataTitleKey] as? String,
            let artist = metadata?[metadataArtistKey] as? String,
            let album = metadata?[metadataAlbumKey] as? String,
            let duration = metadata?[metadataDurationKey] as? Double,
            let fileType = metadata?[metadataFileTypeKey] as? String
        else { return nil }
        let artworkFileName = metadata?[metadataArtworkFileNameKey] as? String
        let trackNumber = metadata?[metadataTrackNumberKey] as? Int
        let discNumber = metadata?[metadataDiscNumberKey] as? Int
        return WatchTransferMeta(
            id: id,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            fileType: fileType,
            artworkFileName: artworkFileName,
            trackNumber: trackNumber,
            discNumber: discNumber
        )
    }

    /// Whether a WatchConnectivity file-transfer metadata dictionary describes an artwork transfer
    /// (see `kindArtwork`) rather than an audio transfer.
    static func isArtworkWcMetadata(_ metadata: [String: Any]?) -> Bool {
        metadata?[metadataKindKey] as? String == kindArtwork
    }

    /// Filesystem-safe stem derived from `id` (song ids may be full desktop paths containing `/`).
    static func storageStem(for id: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let sanitised = id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let stem = String(sanitised)
        return stem.isEmpty ? "untitled" : stem
    }

    /// Stored filename for the transferred audio asset on the Watch (`<sanitised-id>.<fileType>`).
    var storedFileName: String {
        "\(Self.storageStem(for: id)).\(fileType)"
    }

    /// Stored filename for the transferred artwork JPEG on the Watch (`<sanitised-id>.jpg`),
    /// independent of `artworkFileName` (which merely records that one was sent) so the receiver
    /// can resolve it from `id` alone.
    static func storedArtworkFileName(forId id: String) -> String {
        "\(storageStem(for: id)).jpg"
    }
}

/// Pure merge/remove logic for the Watch-side persisted song index (a JSON file under
/// Application Support on the Watch). Kept as free functions with no WatchKit dependency so the
/// behaviour is unit-testable from the iOS test target.
enum WatchLibraryIndex {
    /// Appends `meta` if no entry with the same id exists yet; otherwise updates that entry's
    /// metadata in place, at the same position, rather than leaving it untouched. This used to be
    /// "first write wins" (a re-sent transfer was a no-op), which meant an already-received song
    /// could never pick up fields added to `WatchTransferMeta` later (e.g. trackNumber/discNumber —
    /// see `WatchAlbumGrouping`). Updating in place makes "re-send an album" a real way to repair
    /// the order of songs transferred before that fix.
    static func adding(_ meta: WatchTransferMeta, to songs: [WatchTransferMeta]) -> [WatchTransferMeta] {
        guard let index = songs.firstIndex(where: { $0.id == meta.id }) else {
            return songs + [meta]
        }
        var updated = songs
        updated[index] = meta
        return updated
    }

    /// Removes the entry with `id`, if present. No-op when the id is not in the index.
    static func removing(id: String, from songs: [WatchTransferMeta]) -> [WatchTransferMeta] {
        songs.filter { $0.id != id }
    }

    /// Filters a decoded index down to entries whose backing audio file is confirmed present,
    /// so a manual deletion outside the app (or an interrupted transfer) cannot leave a dangling
    /// row that fails to play.
    static func retainingExistingFiles(
        _ songs: [WatchTransferMeta],
        fileExists: (WatchTransferMeta) -> Bool
    ) -> [WatchTransferMeta] {
        songs.filter(fileExists)
    }
}

/// Outcome of attempting to persist a file received from the iPhone (copy from WatchConnectivity's
/// transient inbox into the Watch's own storage). Kept separate from the WatchConnectivity plumbing
/// so the "what happens to the library index next" decision is unit-testable without a real
/// WCSession/WatchKit environment.
enum WatchFileReceiveResult: Equatable {
    case succeeded(WatchTransferMeta)
    case failed(String)
}

enum WatchFileReceiveHandling {
    /// Whether the library index should be updated (`addSong`) for this result. Only a successful
    /// copy should ever reach the index — a failed copy must not register a song whose audio file
    /// does not actually exist on disk.
    static func shouldAddToLibrary(_ result: WatchFileReceiveResult) -> Bool {
        if case .succeeded = result { return true }
        return false
    }
}
