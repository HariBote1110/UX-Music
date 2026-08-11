import XCTest
@testable import UX_Music_Mobile

final class WatchTransferTests: XCTestCase {

    private func sample(id: String = "abc123") -> WatchTransferMeta {
        WatchTransferMeta(id: id, title: "Song", artist: "Artist", album: "Album", duration: 123.4, fileType: "m4a")
    }

    // MARK: - wcMetadata / fromWCMetadata round trip

    func testWCMetadataRoundTrip() {
        let meta = sample()
        let decoded = WatchTransferMeta.fromWCMetadata(meta.wcMetadata)
        XCTAssertEqual(decoded, meta)
    }

    func testFromWCMetadataReturnsNilWhenKeyMissing() {
        var dict = sample().wcMetadata
        dict.removeValue(forKey: WatchTransferMeta.metadataDurationKey)
        XCTAssertNil(WatchTransferMeta.fromWCMetadata(dict))
    }

    func testFromWCMetadataReturnsNilForWrongType() {
        var dict = sample().wcMetadata
        dict[WatchTransferMeta.metadataDurationKey] = "not-a-number"
        XCTAssertNil(WatchTransferMeta.fromWCMetadata(dict))
    }

    func testFromWCMetadataReturnsNilForNilDictionary() {
        XCTAssertNil(WatchTransferMeta.fromWCMetadata(nil))
    }

    // MARK: - Codable

    func testJSONEncodeDecodeRoundTrip() throws {
        let meta = sample()
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(WatchTransferMeta.self, from: data)
        XCTAssertEqual(decoded, meta)
    }

    // MARK: - storedFileName / storageStem

    func testStoredFileNameSanitisesPathSeparators() {
        let meta = sample(id: "Artist/Album/Song.flac")
        XCTAssertFalse(meta.storedFileName.contains("/"))
        XCTAssertTrue(meta.storedFileName.hasSuffix(".m4a"))
    }

    func testStorageStemIsStableForSameID() {
        XCTAssertEqual(WatchTransferMeta.storageStem(for: "abc/def"), WatchTransferMeta.storageStem(for: "abc/def"))
    }

    func testStorageStemFallsBackForEmptyID() {
        XCTAssertEqual(WatchTransferMeta.storageStem(for: ""), "untitled")
    }

    // MARK: - Display helpers

    func testDisplayFieldsFallBackWhenEmpty() {
        let meta = WatchTransferMeta(id: "1", title: "", artist: "", album: "", duration: 65, fileType: "mp3")
        XCTAssertEqual(meta.displayTitle, "Unknown Title")
        XCTAssertEqual(meta.displayArtist, "Unknown Artist")
        XCTAssertEqual(meta.displayAlbum, "Unknown Album")
        XCTAssertEqual(meta.formattedDuration, "1:05")
    }

    // MARK: - WatchLibraryIndex.adding

    func testAddingAppendsNewEntry() {
        let result = WatchLibraryIndex.adding(sample(id: "1"), to: [])
        XCTAssertEqual(result.map(\.id), ["1"])
    }

    /// Spec change: a re-sent transfer for an already-received song used to be a no-op ("first
    /// write wins"), which meant an old entry could never gain fields added later (e.g.
    /// trackNumber/discNumber — see `WatchAlbumGrouping`). Re-sending now refreshes the existing
    /// entry's metadata in place, at the same position, so "re-send an album to repair its order"
    /// is a real recovery path for songs transferred before this fix.
    func testAddingUpdatesExistingEntryInPlaceForDuplicateID() {
        var updated = sample(id: "1")
        updated.title = "New Title"
        let existing = [sample(id: "1"), sample(id: "2")]
        let result = WatchLibraryIndex.adding(updated, to: existing)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.id), ["1", "2"], "must not move the updated entry's position")
        XCTAssertEqual(result[0].title, "New Title")
    }

    func testAddingPreservesOrder() {
        let existing = [sample(id: "1"), sample(id: "2")]
        let result = WatchLibraryIndex.adding(sample(id: "3"), to: existing)
        XCTAssertEqual(result.map(\.id), ["1", "2", "3"])
    }

    /// `WatchConnectivityReceiver.session(_:didReceive:)` is `nonisolated`, so WatchConnectivity can
    /// invoke it concurrently on background threads for several files arriving close together (e.g.
    /// a bulk album transfer). Each call folds its result into the persisted index via
    /// `WatchLibraryIndex.adding` on the main actor. Regardless of which delegate call happens to be
    /// scheduled first, applying `adding` for every song in *any* interleaving must still retain all
    /// of them — this pins that invariant so a future change to the merge logic (e.g. one that reads
    /// a snapshot instead of folding) cannot silently reintroduce a lost-update race across a bulk
    /// transfer.
    func testAddingRetainsAllEntriesRegardlessOfArrivalOrder() {
        let songs = (1...5).map { sample(id: "song-\($0)") }

        for arrivalOrder in [songs, songs.reversed().map { $0 }, Array(songs[2...]) + Array(songs[..<2])] {
            var index: [WatchTransferMeta] = []
            for meta in arrivalOrder {
                index = WatchLibraryIndex.adding(meta, to: index)
            }
            XCTAssertEqual(Set(index.map(\.id)), Set(songs.map(\.id)), "lost an entry for arrival order \(arrivalOrder.map(\.id))")
        }
    }

    // MARK: - WatchLibraryIndex.removing

    func testRemovingDeletesMatchingID() {
        let existing = [sample(id: "1"), sample(id: "2")]
        let result = WatchLibraryIndex.removing(id: "1", from: existing)
        XCTAssertEqual(result.map(\.id), ["2"])
    }

    func testRemovingIsNoOpWhenIDNotPresent() {
        let existing = [sample(id: "1")]
        let result = WatchLibraryIndex.removing(id: "missing", from: existing)
        XCTAssertEqual(result.map(\.id), ["1"])
    }

    // MARK: - WatchLibraryIndex.retainingExistingFiles

    func testRetainingExistingFilesFiltersMissingFiles() {
        let existing = [sample(id: "1"), sample(id: "2")]
        let result = WatchLibraryIndex.retainingExistingFiles(existing) { $0.id == "1" }
        XCTAssertEqual(result.map(\.id), ["1"])
    }

    // MARK: - WatchFileReceiveHandling

    func testShouldAddToLibraryIsTrueOnSuccess() {
        XCTAssertTrue(WatchFileReceiveHandling.shouldAddToLibrary(.succeeded(sample())))
    }

    func testShouldAddToLibraryIsFalseOnFailure() {
        XCTAssertFalse(WatchFileReceiveHandling.shouldAddToLibrary(.failed("copy failed")))
    }

    // MARK: - WatchTransferActivationGating
    //
    // Pure gating logic for the "activate before transferFile" bug: on a real device,
    // WCSession.activate() completes asynchronously, so a `send` requested before
    // `activationDidCompleteWith` fires must be queued rather than attempted immediately
    // (attempting it immediately is what produced the "WCSession has not been activated" /
    // "Application context data is nil" errors seen on-device).

    func testShouldSendImmediatelyIsFalseBeforeActivation() {
        XCTAssertFalse(WatchTransferActivationGating.shouldSendImmediately(status: .notActivated))
        XCTAssertFalse(WatchTransferActivationGating.shouldSendImmediately(status: .activating))
    }

    func testShouldSendImmediatelyIsTrueOnceActivated() {
        XCTAssertTrue(WatchTransferActivationGating.shouldSendImmediately(status: .activated))
    }

    func testShouldSendImmediatelyIsFalseWhenActivationFailed() {
        XCTAssertFalse(WatchTransferActivationGating.shouldSendImmediately(status: .failed("boom")))
    }

    func testStatusAfterActivationCompletionSucceededIsActivated() {
        XCTAssertEqual(
            WatchTransferActivationGating.statusAfterActivationCompletion(succeeded: true, errorDescription: nil),
            .activated
        )
    }

    func testStatusAfterActivationCompletionFailedCarriesErrorDescription() {
        XCTAssertEqual(
            WatchTransferActivationGating.statusAfterActivationCompletion(succeeded: false, errorDescription: "network gone"),
            .failed("network gone")
        )
    }

    func testStatusAfterActivationCompletionFailedFallsBackToDefaultMessageWhenNoError() {
        XCTAssertEqual(
            WatchTransferActivationGating.statusAfterActivationCompletion(succeeded: false, errorDescription: nil),
            .failed("Watch connectivity activation failed")
        )
    }

    // MARK: - Artwork transfer

    func testWCMetadataOmitsArtworkFileNameWhenNil() {
        XCTAssertNil(sample().wcMetadata[WatchTransferMeta.metadataArtworkFileNameKey])
    }

    func testWCMetadataRoundTripPreservesArtworkFileName() {
        var meta = sample()
        meta.artworkFileName = WatchTransferMeta.storedArtworkFileName(forId: meta.id)
        let decoded = WatchTransferMeta.fromWCMetadata(meta.wcMetadata)
        XCTAssertEqual(decoded, meta)
    }

    // MARK: - trackNumber / discNumber
    //
    // Carried so the Watch can sort within an album by track order instead of assuming transfer
    // order == track order (see `WatchAlbumGrouping`) — that assumption broke once on-device
    // transcoding made `transferFile` calls land in transcode-completion order, not enqueue order.
    // Optional so old persisted Watch index JSON (and metadata from an old sender) still decodes.

    func testWCMetadataRoundTripPreservesTrackAndDiscNumber() {
        var meta = sample()
        meta.trackNumber = 3
        meta.discNumber = 2
        let decoded = WatchTransferMeta.fromWCMetadata(meta.wcMetadata)
        XCTAssertEqual(decoded, meta)
        XCTAssertEqual(decoded?.trackNumber, 3)
        XCTAssertEqual(decoded?.discNumber, 2)
    }

    func testWCMetadataOmitsTrackAndDiscNumberWhenNil() {
        let dict = sample().wcMetadata
        XCTAssertNil(dict[WatchTransferMeta.metadataTrackNumberKey])
        XCTAssertNil(dict[WatchTransferMeta.metadataDiscNumberKey])
    }

    func testFromWCMetadataSucceedsWhenTrackAndDiscNumberKeysMissing() {
        // Simulates decoding metadata sent by an old sender version that predates these fields.
        let dict = sample().wcMetadata
        let decoded = WatchTransferMeta.fromWCMetadata(dict)
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.trackNumber)
        XCTAssertNil(decoded?.discNumber)
    }

    func testJSONDecodeSucceedsWhenTrackAndDiscNumberKeysMissingFromPersistedIndex() throws {
        // Simulates a Watch index JSON persisted before these fields existed.
        let json = """
        {"id":"1","title":"Song","artist":"Artist","album":"Album","duration":123.4,"fileType":"m4a"}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(WatchTransferMeta.self, from: json)
        XCTAssertNil(decoded.trackNumber)
        XCTAssertNil(decoded.discNumber)
    }

    func testJSONEncodeDecodeRoundTripPreservesTrackAndDiscNumber() throws {
        var meta = sample()
        meta.trackNumber = 7
        meta.discNumber = 1
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(WatchTransferMeta.self, from: data)
        XCTAssertEqual(decoded, meta)
    }

    func testArtworkWcMetadataMarksKindArtwork() {
        XCTAssertTrue(WatchTransferMeta.isArtworkWcMetadata(sample().artworkWcMetadata))
    }

    func testIsArtworkWcMetadataIsFalseForAudioMetadata() {
        XCTAssertFalse(WatchTransferMeta.isArtworkWcMetadata(sample().wcMetadata))
    }

    func testIsArtworkWcMetadataIsFalseForNil() {
        XCTAssertFalse(WatchTransferMeta.isArtworkWcMetadata(nil))
    }

    func testStoredArtworkFileNameIsJPEGAndSanitised() {
        let name = WatchTransferMeta.storedArtworkFileName(forId: "Artist/Album/Song")
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.hasSuffix(".jpg"))
    }

    // MARK: - WatchTransferDownloadOutcome
    //
    // Pure phase-transition logic for `WatchTransferBridge.send`'s "download an undownloaded song,
    // then transfer it" path (see WatchTransferBridge.downloadThenQueue). Previously an undownloaded
    // song was rejected outright by `send` with no queue entry at all, which is how a bulk album
    // transfer could silently drop tracks that had not been downloaded yet.

    func testPhaseAfterDownloadIsWaitingOnSuccess() {
        XCTAssertEqual(WatchTransferDownloadOutcome.phaseAfterDownload(succeeded: true), .waiting)
    }

    func testPhaseAfterDownloadIsFailedOnFailure() {
        guard case .failed(let message) = WatchTransferDownloadOutcome.phaseAfterDownload(succeeded: false) else {
            return XCTFail("expected .failed phase")
        }
        XCTAssertFalse(message.isEmpty)
    }

    // MARK: - WatchTransferTranscodeOutcome
    //
    // Pure "what actually gets transferred" decision for `performTransfer`'s transcode-then-send
    // path (see `WatchTransferBridge`): a successful transcode sends the cached AAC file announced
    // as `m4a`; a failed/skipped transcode falls back to the original file/fileType, since a slow
    // transfer of the original beats no transfer at all.

    func testFileToSendUsesTranscodedURLAndM4aFileTypeOnSuccess() {
        let original = URL(fileURLWithPath: "/tmp/original.flac")
        let transcoded = URL(fileURLWithPath: "/tmp/cache/abc123.m4a")
        let result = WatchTransferTranscodeOutcome.fileToSend(
            originalURL: original,
            originalFileType: "flac",
            transcodedURL: transcoded
        )
        XCTAssertEqual(result.url, transcoded)
        XCTAssertEqual(result.fileType, "m4a")
    }

    func testFileToSendFallsBackToOriginalOnTranscodeFailure() {
        let original = URL(fileURLWithPath: "/tmp/original.flac")
        let result = WatchTransferTranscodeOutcome.fileToSend(
            originalURL: original,
            originalFileType: "flac",
            transcodedURL: nil
        )
        XCTAssertEqual(result.url, original)
        XCTAssertEqual(result.fileType, "flac")
    }

    // MARK: - WatchTransferCompletionOutcome
    //
    // Pure phase mapping for `WCSessionDelegate.session(_:didFinish:error:)` — the previous
    // implementation only handled the error branch and left success entirely unmapped, which is how
    // `.sending` (upserted immediately on `transferFile` — itself only an enqueue, not a completed
    // transfer) got shown to the user as if it were done.

    func testCompletionPhaseIsSentWhenNoError() {
        XCTAssertEqual(WatchTransferCompletionOutcome.phase(error: nil), .sent)
    }

    func testCompletionPhaseIsFailedWithReasonOnError() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "connection lost"])
        XCTAssertEqual(WatchTransferCompletionOutcome.phase(error: error), .failed("connection lost"))
    }

    // MARK: - WatchTransferQueueSummary
    //
    // Pure aggregate for the Settings screen's queue summary header ("完了 m/n" + an aggregate
    // ProgressView while any item is still `.sending`/`.preparing`) — see `SettingsScreen`.

    func testAggregateOfEmptyQueue() {
        let result = WatchTransferQueueSummary.aggregate(items: [])
        XCTAssertEqual(result.completedCount, 0)
        XCTAssertEqual(result.totalCount, 0)
        XCTAssertEqual(result.meanFraction, 0)
        XCTAssertFalse(result.isActive)
    }

    private func item(id: String, phase: WatchTransferQueueItem.Phase) -> WatchTransferQueueItem {
        WatchTransferQueueItem(id: id, title: "Song \(id)", phase: phase)
    }

    func testAggregateAllSent() {
        let items = [item(id: "1", phase: .sent), item(id: "2", phase: .sent)]
        let result = WatchTransferQueueSummary.aggregate(items: items)
        XCTAssertEqual(result.completedCount, 2)
        XCTAssertEqual(result.totalCount, 2)
        XCTAssertEqual(result.meanFraction, 1.0)
        XCTAssertFalse(result.isActive)
    }

    func testAggregateMixedPhases() {
        let items = [
            item(id: "1", phase: .sent),
            item(id: "2", phase: .sending(0.5)),
            item(id: "3", phase: .waiting)
        ]
        let result = WatchTransferQueueSummary.aggregate(items: items)
        XCTAssertEqual(result.completedCount, 1)
        XCTAssertEqual(result.totalCount, 3)
        XCTAssertEqual(result.meanFraction, 0.5, accuracy: 0.0001)
        XCTAssertTrue(result.isActive)
    }

    func testAggregateIsActiveWhilePreparingEvenWithNoSendingItems() {
        let items = [item(id: "1", phase: .preparing), item(id: "2", phase: .waiting)]
        let result = WatchTransferQueueSummary.aggregate(items: items)
        XCTAssertTrue(result.isActive)
        XCTAssertEqual(result.meanFraction, 0)
    }

    // MARK: - ProgressPublishThrottle
    //
    // Shared throttle for high-frequency progress callbacks (Watch transfer KVO
    // `fractionCompleted`, `AppModel.downloadProgress`) — publishing every tick would hammer
    // SwiftUI, so updates are only surfaced in ~1% steps (always publishing on reaching 1.0 so a
    // completed transfer/download never gets stuck showing 99%).

    func testShouldPublishFalseForSubStepAdvance() {
        XCTAssertFalse(ProgressPublishThrottle.shouldPublish(previous: 0, next: 0.005))
    }

    func testShouldPublishTrueAtStepBoundary() {
        XCTAssertTrue(ProgressPublishThrottle.shouldPublish(previous: 0, next: 0.01))
    }

    func testShouldPublishTrueForLargeAdvance() {
        XCTAssertTrue(ProgressPublishThrottle.shouldPublish(previous: 0.2, next: 0.5))
    }

    func testShouldPublishAlwaysTrueOnReachingComplete() {
        XCTAssertTrue(ProgressPublishThrottle.shouldPublish(previous: 0.995, next: 1.0))
    }

    func testShouldPublishFalseWhenNoAdvance() {
        XCTAssertFalse(ProgressPublishThrottle.shouldPublish(previous: 0.5, next: 0.5))
    }

    // MARK: - WatchTransferWorkQueue
    //
    // Pure FIFO ordering for `WatchTransferBridge`'s transcode→send worker. Fixes the bug where a
    // per-song detached `Task` in the old `performTransfer` let `WCSession.transferFile` calls land
    // in transcode-completion order (short songs finish first) rather than enqueue order, scrambling
    // album track order on the Watch. Draining strictly FIFO — one song fully handled before the
    // next starts — makes `transferFile` calls happen in enqueue order regardless of how long any
    // individual transcode takes.

    private func workSong(_ id: String) -> Song {
        Song(id: id, path: "/tmp/\(id).flac", title: id)
    }

    func testEnqueuingAppendsToBackOfQueue() {
        let queue = WatchTransferWorkQueue.enqueuing(workSong("2"), onto: [workSong("1")])
        XCTAssertEqual(queue.map(\.id), ["1", "2"])
    }

    func testDequeuingFrontReturnsFirstSongAndRemainder() {
        let queue = [workSong("1"), workSong("2"), workSong("3")]
        let result = WatchTransferWorkQueue.dequeuingFront(from: queue)
        XCTAssertEqual(result?.song.id, "1")
        XCTAssertEqual(result?.remaining.map(\.id), ["2", "3"])
    }

    func testDequeuingFrontReturnsNilForEmptyQueue() {
        XCTAssertNil(WatchTransferWorkQueue.dequeuingFront(from: []))
    }

    /// Simulates a full drain and pins that the resulting send order matches enqueue order,
    /// independent of anything that would happen between each dequeue (e.g. a slow transcode) —
    /// the real bug this fixes was send order depending on transcode duration.
    func testDrainingQueueSequentiallyPreservesEnqueueOrder() {
        var queue: [Song] = []
        for id in ["slow-1", "fast-2", "medium-3"] {
            queue = WatchTransferWorkQueue.enqueuing(workSong(id), onto: queue)
        }

        var sentOrder: [String] = []
        while let (song, remaining) = WatchTransferWorkQueue.dequeuingFront(from: queue) {
            queue = remaining
            sentOrder.append(song.id)
        }

        XCTAssertEqual(sentOrder, ["slow-1", "fast-2", "medium-3"])
    }

    // MARK: - WatchTransferQueuePersistence
    //
    // User report: "アプリ閉じちゃうと転送止まっちゃう" — the iPhone-side queue used to live only in
    // `WatchTransferBridge.queue` (an in-memory `@Published` array), so killing the iPhone app lost
    // track of every song that had not finished sending yet. This snapshots the still-pending subset
    // (not `.sent`/`.failed`) to UserDefaults so a relaunch can resume them (see
    // `WatchTransferRestoreReconciliation` below for the resume-side logic).

    func testPendingSnapshotExcludesSentAndFailedItems() {
        let queue = [
            item(id: "1", phase: .sent),
            item(id: "2", phase: .failed("boom")),
            item(id: "3", phase: .waiting)
        ]
        let snapshot = WatchTransferQueuePersistence.pendingSnapshot(from: queue)
        XCTAssertEqual(snapshot.map(\.id), ["3"])
    }

    func testPendingSnapshotIncludesEveryInFlightPhase() {
        let queue = [
            item(id: "1", phase: .downloading),
            item(id: "2", phase: .waiting),
            item(id: "3", phase: .preparing),
            item(id: "4", phase: .sending(0.4))
        ]
        let snapshot = WatchTransferQueuePersistence.pendingSnapshot(from: queue)
        XCTAssertEqual(snapshot.map(\.id), ["1", "2", "3", "4"])
    }

    func testPendingSnapshotPreservesQueueOrder() {
        let queue = [item(id: "z", phase: .waiting), item(id: "a", phase: .waiting)]
        let snapshot = WatchTransferQueuePersistence.pendingSnapshot(from: queue)
        XCTAssertEqual(snapshot.map(\.id), ["z", "a"])
    }

    func testPendingSnapshotCarriesTitle() {
        let queue = [item(id: "1", phase: .waiting)]
        let snapshot = WatchTransferQueuePersistence.pendingSnapshot(from: queue)
        XCTAssertEqual(snapshot.first?.title, "Song 1")
    }

    func testShouldPersistIsFalseWhenSnapshotUnchanged() {
        let snapshot = [WatchTransferPendingQueueEntry(id: "1", title: "Song 1")]
        XCTAssertFalse(WatchTransferQueuePersistence.shouldPersist(current: snapshot, lastPersisted: snapshot))
    }

    func testShouldPersistIsTrueWhenSnapshotDiffers() {
        let previous = [WatchTransferPendingQueueEntry(id: "1", title: "Song 1")]
        let current = [WatchTransferPendingQueueEntry(id: "1", title: "Song 1"), WatchTransferPendingQueueEntry(id: "2", title: "Song 2")]
        XCTAssertTrue(WatchTransferQueuePersistence.shouldPersist(current: current, lastPersisted: previous))
    }

    func testShouldPersistIsTrueWhenNothingPersistedYet() {
        let current = [WatchTransferPendingQueueEntry(id: "1", title: "Song 1")]
        XCTAssertTrue(WatchTransferQueuePersistence.shouldPersist(current: current, lastPersisted: nil))
    }

    func testPendingQueueEntryCodableRoundTrip() throws {
        let entry = WatchTransferPendingQueueEntry(id: "abc/def", title: "Song Title")
        let data = try JSONEncoder().encode([entry])
        let decoded = try JSONDecoder().decode([WatchTransferPendingQueueEntry].self, from: data)
        XCTAssertEqual(decoded, [entry])
    }

    // MARK: - WatchTransferRestoreReconciliation
    //
    // Pure reconciliation for resuming a persisted pending queue on relaunch: for each persisted
    // entry, decide whether it is still actively transferring (present in
    // `WCSession.outstandingFileTransfers` — reattach progress), resumable (downloaded locally, not
    // outstanding — re-enter the FIFO work queue in persisted order, preserving the ordering fix from
    // `progress/watch-transfer-order.md`), or unresumable (no longer downloaded — mark failed).

    private func pendingEntry(_ id: String, title: String? = nil) -> WatchTransferPendingQueueEntry {
        WatchTransferPendingQueueEntry(id: id, title: title ?? "Song \(id)")
    }

    func testReconciliationResumesOutstandingTransfersWithLiveProgress() {
        let plan = WatchTransferRestoreReconciliation.plan(
            persisted: [pendingEntry("1")],
            outstanding: [WatchTransferRestoreReconciliation.OutstandingTransfer(id: "1", fraction: 0.7)],
            downloadedSongIds: []
        )
        XCTAssertEqual(plan.toResumeSending.map(\.id), ["1"])
        XCTAssertEqual(plan.toResumeSending.first?.phase, .sending(0.7))
        XCTAssertTrue(plan.toReenqueueSongIds.isEmpty)
        XCTAssertTrue(plan.toMarkFailed.isEmpty)
    }

    func testReconciliationReenqueuesDownloadedNonOutstandingEntries() {
        let plan = WatchTransferRestoreReconciliation.plan(
            persisted: [pendingEntry("1")],
            outstanding: [],
            downloadedSongIds: ["1"]
        )
        XCTAssertEqual(plan.toReenqueueSongIds, ["1"])
        XCTAssertTrue(plan.toResumeSending.isEmpty)
        XCTAssertTrue(plan.toMarkFailed.isEmpty)
    }

    func testReconciliationMarksFailedWhenNoLongerDownloadedAndNotOutstanding() {
        let plan = WatchTransferRestoreReconciliation.plan(
            persisted: [pendingEntry("1")],
            outstanding: [],
            downloadedSongIds: []
        )
        XCTAssertTrue(plan.toReenqueueSongIds.isEmpty)
        XCTAssertTrue(plan.toResumeSending.isEmpty)
        XCTAssertEqual(plan.toMarkFailed.map(\.id), ["1"])
        guard case .failed(let message) = plan.toMarkFailed.first?.phase else {
            return XCTFail("expected .failed phase")
        }
        XCTAssertFalse(message.isEmpty)
    }

    /// Pins the FIFO ordering guarantee: songs must re-enter the transfer work queue in the order
    /// they were persisted, not e.g. outstanding-transfer order or download-resolution order.
    func testReconciliationPreservesPersistedOrderForReenqueuedSongs() {
        let plan = WatchTransferRestoreReconciliation.plan(
            persisted: [pendingEntry("slow-1"), pendingEntry("fast-2"), pendingEntry("medium-3")],
            outstanding: [],
            downloadedSongIds: ["slow-1", "fast-2", "medium-3"]
        )
        XCTAssertEqual(plan.toReenqueueSongIds, ["slow-1", "fast-2", "medium-3"])
    }

    func testReconciliationHandlesMixOfAllThreeOutcomes() {
        let plan = WatchTransferRestoreReconciliation.plan(
            persisted: [pendingEntry("outstanding-1"), pendingEntry("resumable-2"), pendingEntry("gone-3")],
            outstanding: [WatchTransferRestoreReconciliation.OutstandingTransfer(id: "outstanding-1", fraction: 0.3)],
            downloadedSongIds: ["resumable-2"]
        )
        XCTAssertEqual(plan.toResumeSending.map(\.id), ["outstanding-1"])
        XCTAssertEqual(plan.toReenqueueSongIds, ["resumable-2"])
        XCTAssertEqual(plan.toMarkFailed.map(\.id), ["gone-3"])
    }

    func testReconciliationOutstandingTakesPriorityOverDownloadedCheck() {
        // A song can be both "outstanding" (still transferring) and "downloaded" — outstanding must
        // win so its live progress is reattached rather than being redundantly re-sent from scratch.
        let plan = WatchTransferRestoreReconciliation.plan(
            persisted: [pendingEntry("1")],
            outstanding: [WatchTransferRestoreReconciliation.OutstandingTransfer(id: "1", fraction: 0.9)],
            downloadedSongIds: ["1"]
        )
        XCTAssertEqual(plan.toResumeSending.map(\.id), ["1"])
        XCTAssertTrue(plan.toReenqueueSongIds.isEmpty)
    }

    func testReconciliationOfEmptyPersistedQueueProducesEmptyPlan() {
        let plan = WatchTransferRestoreReconciliation.plan(persisted: [], outstanding: [], downloadedSongIds: [])
        XCTAssertTrue(plan.toResumeSending.isEmpty)
        XCTAssertTrue(plan.toReenqueueSongIds.isEmpty)
        XCTAssertTrue(plan.toMarkFailed.isEmpty)
    }
}
