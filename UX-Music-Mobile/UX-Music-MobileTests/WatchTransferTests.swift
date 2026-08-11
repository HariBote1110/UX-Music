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
}
