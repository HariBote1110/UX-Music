import Foundation
import UIKit
import WatchConnectivity

/// One song queued (or already sent) to the paired Apple Watch.
struct WatchTransferQueueItem: Identifiable, Equatable {
    enum Phase: Equatable {
        case downloading
        case waiting
        /// `WatchTransferAudioPolicy` decided the local file needs transcoding to AAC before it can
        /// be sent (see `WatchTransferBridge.performTransfer`); `WatchAudioTranscoder` is running.
        case preparing
        /// `WCSession.transferFile` was enqueued and is in flight; the associated value is
        /// `WCSessionFileTransfer.progress.fractionCompleted` (0.0–1.0), observed via KVO in
        /// `WatchTransferBridge.sendFile` and throttled by `ProgressPublishThrottle`. `transferFile`
        /// only *enqueues* the transfer — it does not mean any bytes have moved yet — so this used
        /// to jump straight to `.sent` the instant it was called, showing "Sent" for a multi-minute
        /// transfer that had not even started.
        case sending(Double)
        /// `WCSessionDelegate.session(_:didFinish:error:)` reported success.
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
        succeeded ? .waiting : .failed(String(localized: "Download failed. Check the connection to the desktop app."))
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

/// Pure phase mapping for `WCSessionDelegate.session(_:didFinish:error:)` — kept as a free function
/// (no `WCSession` dependency) so the success/failure mapping is unit-testable. Previously this
/// delegate callback only handled the error branch (a success left the queue item however `sendFile`
/// had already (wrongly) set it, i.e. `.sent` before the transfer had actually finished).
enum WatchTransferCompletionOutcome {
    static func phase(error: Error?) -> WatchTransferQueueItem.Phase {
        if let error {
            return .failed(error.localizedDescription)
        }
        return .sent
    }
}

/// Pure FIFO ordering for `WatchTransferBridge`'s transcode→send worker (see `performTransfer`).
/// A song that needs transcoding used to be handled by its own detached `Task`, so multiple songs'
/// transcodes ran concurrently and `WCSession.transferFile` — which only happens after a song's
/// transcode finishes — ended up called in transcode-completion order (short songs finish first),
/// not the order the songs were enqueued in. Since WatchConnectivity delivers files in the order
/// `transferFile` was called, that scrambled album track order on the Watch. Draining this queue
/// one song at a time, front to back, makes `transferFile` calls happen in enqueue order regardless
/// of how long any individual transcode takes. Kept as free functions over `[Song]` (no `WCSession`/
/// `WatchAudioTranscoder` dependency) so the FIFO invariant is unit-testable on its own.
enum WatchTransferWorkQueue {
    /// Appends `song` to the back of `queue`.
    static func enqueuing(_ song: Song, onto queue: [Song]) -> [Song] {
        queue + [song]
    }

    /// Removes and returns the song at the front of `queue`, alongside the remaining queue.
    /// `nil` when `queue` is empty.
    static func dequeuingFront(from queue: [Song]) -> (song: Song, remaining: [Song])? {
        guard let first = queue.first else { return nil }
        return (first, Array(queue.dropFirst()))
    }
}

/// Aggregate progress across `WatchTransferBridge.queue`, used by the Settings screen's queue
/// summary header ("完了 m/n" plus an aggregate `ProgressView` while any item is still in flight —
/// see `SettingsScreen`). Kept as a pure function over `[WatchTransferQueueItem]` so the aggregation
/// policy is unit-testable without a real `WCSession`.
enum WatchTransferQueueSummary {
    struct Aggregate: Equatable {
        /// Number of items whose phase is `.sent`.
        let completedCount: Int
        let totalCount: Int
        /// Mean of every item's fraction: `1.0` for `.sent`, the in-progress fraction for
        /// `.sending`, `0` for every other phase. `0` for an empty queue.
        let meanFraction: Double
        /// Whether any item is still actively transferring or being prepared — the header's
        /// aggregate `ProgressView` is only shown while this is `true`.
        let isActive: Bool
    }

    static func aggregate(items: [WatchTransferQueueItem]) -> Aggregate {
        guard !items.isEmpty else {
            return Aggregate(completedCount: 0, totalCount: 0, meanFraction: 0, isActive: false)
        }

        var completedCount = 0
        var fractionSum = 0.0
        var isActive = false

        for item in items {
            switch item.phase {
            case .sent:
                completedCount += 1
                fractionSum += 1.0
            case .sending(let fraction):
                fractionSum += fraction
                isActive = true
            case .preparing:
                isActive = true
            case .downloading, .waiting, .failed:
                break
            }
        }

        return Aggregate(
            completedCount: completedCount,
            totalCount: items.count,
            meanFraction: fractionSum / Double(items.count),
            isActive: isActive
        )
    }
}

/// One still-pending (not `.sent`/`.failed`) entry persisted across app launches — see
/// `WatchTransferQueuePersistence`. Deliberately carries only `id`/`title` (not the full `Phase`):
/// on restore, the phase is re-derived from live state (`WCSession.outstandingFileTransfers`,
/// `DownloadManager.downloadedSongs`) rather than trusted from a stale snapshot — see
/// `WatchTransferRestoreReconciliation`.
struct WatchTransferPendingQueueEntry: Codable, Equatable {
    let id: String
    let title: String
}

/// Pure logic for persisting `WatchTransferBridge.queue`'s still-pending subset to UserDefaults, so
/// killing the iPhone app does not silently lose track of songs that had not finished sending yet
/// (user report: "アプリ閉じちゃうと転送止まっちゃう"). Kept as free functions over
/// `[WatchTransferQueueItem]`/`[WatchTransferPendingQueueEntry]` (no `UserDefaults` dependency) so
/// both the subset selection and the write-avoidance check are unit-testable; the actual
/// UserDefaults read/write stays thin plumbing in `WatchTransferBridge`.
enum WatchTransferQueuePersistence {
    /// The subset of `queue` worth persisting: everything except `.sent` (done, nothing to resume)
    /// and `.failed` (already a terminal, user-visible error — resuming it would just fail again),
    /// in queue order.
    static func pendingSnapshot(from queue: [WatchTransferQueueItem]) -> [WatchTransferPendingQueueEntry] {
        queue.compactMap { item in
            switch item.phase {
            case .sent, .failed:
                return nil
            case .downloading, .waiting, .preparing, .sending:
                return WatchTransferPendingQueueEntry(id: item.id, title: item.title)
            }
        }
    }

    /// Whether `current` is worth writing to UserDefaults given what was last persisted — the queue
    /// changes on every KVO progress tick (`sendFile`'s `.sending(fraction)` upserts), but the
    /// persisted subset only needs to change when an item enters/leaves the pending set or its title
    /// changes, so most of those ticks should not trigger a write.
    static func shouldPersist(current: [WatchTransferPendingQueueEntry], lastPersisted: [WatchTransferPendingQueueEntry]?) -> Bool {
        current != lastPersisted
    }
}

/// Pure reconciliation for resuming a persisted pending queue (`WatchTransferQueuePersistence`) once
/// `WCSession` activation completes after an app relaunch. For each persisted entry, decides whether
/// it is:
/// - still actively transferring (`id` present in `WCSession.outstandingFileTransfers`) — reattach
///   live progress rather than re-sending from scratch;
/// - resumable (downloaded locally, not outstanding) — re-enter the FIFO transfer work queue
///   (`WatchTransferWorkQueue`) so it gets a fresh `transferFile` call; or
/// - unresumable (no longer downloaded, e.g. the user deleted the local file while the app was
///   closed) — mark `.failed` with a reason the user can see instead of silently vanishing.
///
/// Kept as a free function (no `WCSession`/`DownloadManager` dependency) so the three-way split and
/// the ordering guarantee are unit-testable without a real session or file system.
enum WatchTransferRestoreReconciliation {
    struct OutstandingTransfer: Equatable {
        let id: String
        let fraction: Double
    }

    struct Plan: Equatable {
        /// Persisted entries with a live `WCSessionFileTransfer` still in flight, re-expressed as
        /// `.sending(fraction)` queue items ready to `upsert`.
        let toResumeSending: [WatchTransferQueueItem]
        /// Song ids to re-enqueue into the FIFO transfer work queue, **in persisted order** — this
        /// is what keeps the ordering fix from `progress/watch-transfer-order.md` intact across a
        /// relaunch (re-enqueuing in any other order would scramble album track order again).
        let toReenqueueSongIds: [String]
        /// Persisted entries that can no longer be resolved to a downloaded `Song`, re-expressed as
        /// `.failed` queue items ready to `upsert`.
        let toMarkFailed: [WatchTransferQueueItem]
    }

    static func plan(
        persisted: [WatchTransferPendingQueueEntry],
        outstanding: [OutstandingTransfer],
        downloadedSongIds: Set<String>
    ) -> Plan {
        let outstandingFractionsById = Dictionary(uniqueKeysWithValues: outstanding.map { ($0.id, $0.fraction) })

        var toResumeSending: [WatchTransferQueueItem] = []
        var toReenqueueSongIds: [String] = []
        var toMarkFailed: [WatchTransferQueueItem] = []

        for entry in persisted {
            // Outstanding takes priority over "is it downloaded" — a song can be both (still
            // transferring, and its local file obviously still exists), and reattaching its live
            // progress is strictly better than redundantly re-sending it from scratch.
            if let fraction = outstandingFractionsById[entry.id] {
                toResumeSending.append(WatchTransferQueueItem(id: entry.id, title: entry.title, phase: .sending(fraction)))
            } else if downloadedSongIds.contains(entry.id) {
                toReenqueueSongIds.append(entry.id)
            } else {
                toMarkFailed.append(WatchTransferQueueItem(
                    id: entry.id,
                    title: entry.title,
                    phase: .failed(String(localized: "No longer downloaded"))
                ))
            }
        }

        return Plan(toResumeSending: toResumeSending, toReenqueueSongIds: toReenqueueSongIds, toMarkFailed: toMarkFailed)
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

    /// In-flight audio `WCSessionFileTransfer`s, keyed by song id — artwork transfers (sent
    /// separately, see `sendFile`) are deliberately not tracked here, so their progress stays
    /// silent and `didFinish` never mutates the queue for them (see `handleTransferCompletion`).
    private var activeTransfers: [String: WCSessionFileTransfer] = [:]
    /// KVO observation of each tracked transfer's `progress.fractionCompleted`, kept alongside
    /// `activeTransfers` so it can be invalidated once the transfer finishes (`handleTransferCompletion`).
    private var transferObservations: [String: NSKeyValueObservation] = [:]
    /// Last fraction upserted into the queue for a given song id, so `ProgressPublishThrottle` has
    /// something to compare each new KVO callback against.
    private var lastPublishedFraction: [String: Double] = [:]

    /// Songs waiting for `transcodeAndSend` (see `performTransfer`/`WatchTransferWorkQueue`) — one
    /// song is fully handled (transcode if needed, then `transferFile`) before the next starts, so
    /// `transferFile` calls always happen in the order songs were enqueued here.
    private var transferWorkQueue: [Song] = []
    /// Whether `drainTransferWorkQueue` is currently running, so `performTransfer` does not start a
    /// second concurrent drain loop.
    private var isDrainingTransferWorkQueue = false

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
            upsert(WatchTransferQueueItem(id: song.id, title: song.displayTitle, phase: .failed(String(localized: "Download is not available"))))
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

    /// Enqueues `song` onto `transferWorkQueue` and starts the drain worker if it is not already
    /// running. Only safe to call once `activationStatus == .activated`.
    ///
    /// Transcode-then-send used to run per-song on its own detached `Task`, so several songs'
    /// transcodes ran concurrently and `sendFile` (and therefore `WCSession.transferFile`) ended up
    /// called in transcode-completion order rather than enqueue order — a short song could finish
    /// transcoding before a long one enqueued earlier, jumping ahead of it in the Watch's received
    /// order. Routing every song through this single FIFO queue instead guarantees `transferFile`
    /// calls happen in the order songs were queued.
    private func performTransfer(_ song: Song) {
        transferWorkQueue = WatchTransferWorkQueue.enqueuing(song, onto: transferWorkQueue)
        startDrainingTransferWorkQueueIfNeeded()
    }

    /// Starts `drainTransferWorkQueue` unless a drain is already in flight (in which case the newly
    /// enqueued song will simply be picked up by that same loop).
    private func startDrainingTransferWorkQueueIfNeeded() {
        guard !isDrainingTransferWorkQueue, !transferWorkQueue.isEmpty else { return }
        isDrainingTransferWorkQueue = true
        Task {
            await drainTransferWorkQueue()
        }
    }

    /// Drains `transferWorkQueue` strictly front-to-back, awaiting each song's `transcodeAndSend`
    /// fully (transcode if needed, then `sendFile`) before dequeuing the next — this sequencing,
    /// not just the FIFO data structure, is what keeps `transferFile` calls in enqueue order.
    private func drainTransferWorkQueue() async {
        while let (song, remaining) = WatchTransferWorkQueue.dequeuingFront(from: transferWorkQueue) {
            transferWorkQueue = remaining
            await transcodeAndSend(song)
        }
        isDrainingTransferWorkQueue = false
    }

    /// Decides (via `WatchTransferAudioPolicy`) whether the local file needs transcoding before it
    /// can be sent, then either sends it immediately or transcodes first. Runs to completion before
    /// `drainTransferWorkQueue` starts the next song.
    private func transcodeAndSend(_ song: Song) async {
        // Prefers the AAC variant (see `DownloadManager.watchTransferSourceURL`) when one was
        // downloaded (`DownloadAudioQuality.aac`/`.both`): it is already 128 kbps m4a, so
        // `WatchTransferAudioPolicy` below naturally resolves to `.passthrough` and the on-device
        // `WatchAudioTranscoder` is skipped entirely. Falls back to `localPathString` (original-only
        // downloads) when no AAC variant exists.
        let localURL = downloadManager.watchTransferSourceURL(songId: song.id)
            ?? URL(fileURLWithPath: downloadManager.localPathString(songId: song.id))
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
        sendFile(fileToSend.url, fileType: fileToSend.fileType, song: song)
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
            fileType: fileType,
            // `Song.trackNumber`/`discNumber` default to 0 for "unknown" (see `Song.swift`); map
            // that to `nil` so `WatchAlbumGrouping` treats it as "no number" rather than track 0.
            trackNumber: song.trackNumber > 0 ? song.trackNumber : nil,
            discNumber: song.discNumber > 0 ? song.discNumber : nil
        )
        if hasArtwork {
            meta.artworkFileName = WatchTransferMeta.storedArtworkFileName(forId: song.id)
        }

        upsert(WatchTransferQueueItem(id: song.id, title: song.displayTitle, phase: .sending(0)))
        lastPublishedFraction[song.id] = 0

        guard WCSession.isSupported() else {
            upsert(WatchTransferQueueItem(id: song.id, title: song.displayTitle, phase: .failed("WatchConnectivity unsupported")))
            return
        }
        let session = WCSession.default
        guard session.activationState == .activated else {
            upsert(WatchTransferQueueItem(id: song.id, title: song.displayTitle, phase: .failed("Watch not connected")))
            return
        }

        // `transferFile` only *enqueues* the transfer — completion (success or failure) arrives
        // later via `WCSessionDelegate.session(_:didFinish:error:)` (see `handleTransferCompletion`),
        // and in-flight progress arrives via KVO on the returned `WCSessionFileTransfer.progress`
        // below. Only the audio transfer is tracked; the artwork transfer further down is fire-and-
        // forget.
        let audioTransfer = session.transferFile(fileURL, metadata: meta.wcMetadata)
        activeTransfers[song.id] = audioTransfer
        transferObservations[song.id] = audioTransfer.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                self?.handleTransferProgress(songId: song.id, fraction: fraction)
            }
        }

        // Artwork is sent as its own `transferFile` rather than embedded in `meta.wcMetadata`
        // (WatchConnectivity metadata dictionaries are meant for small key/value pairs, not image
        // bytes) — downscaled here so the transfer stays small and quick over Bluetooth/Wi-Fi.
        if let artworkURL = downloadManager.localArtworkFileURLIfPresent(artworkId: song.artworkId),
           let downscaledURL = Self.writeDownscaledArtwork(from: artworkURL, songId: song.id) {
            session.transferFile(downscaledURL, metadata: meta.artworkWcMetadata)
        }
    }

    /// KVO callback for a tracked audio transfer's `progress.fractionCompleted`, throttled via
    /// `ProgressPublishThrottle` so SwiftUI is not re-rendering the queue row on every tick.
    private func handleTransferProgress(songId: String, fraction: Double) {
        let previous = lastPublishedFraction[songId] ?? 0
        guard ProgressPublishThrottle.shouldPublish(previous: previous, next: fraction) else { return }
        lastPublishedFraction[songId] = fraction
        guard let title = queue.first(where: { $0.id == songId })?.title else { return }
        upsert(WatchTransferQueueItem(id: songId, title: title, phase: .sending(fraction)))
    }

    /// `WCSessionDelegate.session(_:didFinish:error:)` for a tracked audio transfer: resolves the
    /// final phase via `WatchTransferCompletionOutcome`, restores the item's title from the existing
    /// queue entry (the delegate callback itself only carries the WatchConnectivity metadata, not a
    /// display title), and tears down the KVO observation/tracking entries.
    private func handleTransferCompletion(songId: String, error: Error?) {
        transferObservations[songId]?.invalidate()
        transferObservations.removeValue(forKey: songId)
        activeTransfers.removeValue(forKey: songId)
        lastPublishedFraction.removeValue(forKey: songId)

        let title = queue.first(where: { $0.id == songId })?.title ?? ""
        upsert(WatchTransferQueueItem(id: songId, title: title, phase: WatchTransferCompletionOutcome.phase(error: error)))
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
        let metadata = fileTransfer.file.metadata
        // Artwork transfers are deliberately untracked (see `sendFile`/`activeTransfers`) — silently
        // ignore their completion rather than mutating the queue with an artwork-only "song".
        guard !WatchTransferMeta.isArtworkWcMetadata(metadata) else { return }
        guard let songId = metadata?[WatchTransferMeta.metadataIDKey] as? String else { return }
        Task { @MainActor in
            self.handleTransferCompletion(songId: songId, error: error)
        }
    }
}
