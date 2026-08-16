import XCTest
@testable import UX_Music_Mobile

/// Covers `MusicPlayerService`'s queue/shuffle/repeat surface using songs whose `path` does not
/// exist on disk — `loadAndPlay`/`loadActive` no-op cleanly on a missing file (see
/// `MusicPlayerService.loadAndPlay`'s `FileManager.default.fileExists` guard), so `play(_:newQueue:)`
/// exercises the queue bookkeeping without needing a real audio file or engine playback.
@MainActor
final class MusicPlayerServiceQueueTests: XCTestCase {
    private func song(_ id: String) -> Song {
        Song(id: id, path: "/nonexistent/\(id).m4a", title: id)
    }

    private func songs(_ ids: [String]) -> [Song] {
        ids.map(song)
    }

    // MARK: - Repeat mode

    func testRepeatModeDefaultsToOff() {
        UserDefaults.standard.removeObject(forKey: "uxmusic.playback.repeatMode")
        let player = MusicPlayerService()
        XCTAssertEqual(player.repeatMode, .off)
    }

    func testSetRepeatModePersistsAcrossInstances() {
        let player = MusicPlayerService()
        player.setRepeatMode(.all)
        let reloaded = MusicPlayerService()
        XCTAssertEqual(reloaded.repeatMode, .all)
        player.setRepeatMode(.off)
    }

    func testCycleRepeatModeGoesOffAllOneOff() {
        let player = MusicPlayerService()
        player.setRepeatMode(.off)
        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .all)
        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .one)
        player.cycleRepeatMode()
        XCTAssertEqual(player.repeatMode, .off)
    }

    // MARK: - Shuffle

    func testToggleShuffleOnReordersButKeepsCurrentSongPlaying() async {
        let player = MusicPlayerService()
        player.setShuffleEnabled(false)
        let queue = songs(["A", "B", "C", "D", "E"])
        await player.play(queue[2], newQueue: queue)
        XCTAssertEqual(player.currentSong?.id, "C")

        player.setShuffleEnabled(true)

        XCTAssertTrue(player.isShuffleEnabled)
        XCTAssertEqual(player.currentSong?.id, "C")
        XCTAssertEqual(player.playbackQueue[player.currentQueueIndex].id, "C")
        XCTAssertEqual(Set(player.playbackQueue.map(\.id)), Set(["A", "B", "C", "D", "E"]))
    }

    func testToggleShuffleOffRestoresOriginalOrderAndRecomputesIndex() async {
        let player = MusicPlayerService()
        player.setShuffleEnabled(false)
        let queue = songs(["A", "B", "C", "D"])
        await player.play(queue[0], newQueue: queue)
        player.setShuffleEnabled(true)

        player.setShuffleEnabled(false)

        XCTAssertFalse(player.isShuffleEnabled)
        XCTAssertEqual(player.playbackQueue.map(\.id), ["A", "B", "C", "D"])
        XCTAssertEqual(player.playbackQueue[player.currentQueueIndex].id, "A")
    }

    func testShuffleEnabledPersistsAcrossInstances() {
        let player = MusicPlayerService()
        player.setShuffleEnabled(true)
        let reloaded = MusicPlayerService()
        XCTAssertTrue(reloaded.isShuffleEnabled)
        player.setShuffleEnabled(false)
    }

    // MARK: - Queue editing: move

    func testMoveQueueItemKeepsCurrentSongWhenMovingAnotherItem() async {
        let player = MusicPlayerService()
        let queue = songs(["A", "B", "C", "D"])
        await player.play(queue[2], newQueue: queue) // current = C, index 2

        player.moveQueueItem(from: 0, to: 3) // move A to the end

        XCTAssertEqual(player.playbackQueue.map(\.id), ["B", "C", "D", "A"])
        XCTAssertEqual(player.currentSong?.id, "C")
        XCTAssertEqual(player.playbackQueue[player.currentQueueIndex].id, "C")
    }

    func testMoveQueueItemMovingCurrentSongTracksNewPosition() async {
        let player = MusicPlayerService()
        let queue = songs(["A", "B", "C", "D"])
        await player.play(queue[0], newQueue: queue) // current = A, index 0

        player.moveQueueItem(from: 0, to: 3)

        XCTAssertEqual(player.playbackQueue.map(\.id), ["B", "C", "D", "A"])
        XCTAssertEqual(player.currentQueueIndex, 3)
        XCTAssertEqual(player.currentSong?.id, "A")
    }

    // MARK: - Queue editing: remove

    func testRemoveQueueItemBeforeCurrentShiftsIndexDown() async {
        let player = MusicPlayerService()
        let queue = songs(["A", "B", "C"])
        await player.play(queue[2], newQueue: queue) // current = C, index 2

        await player.removeQueueItem(at: 0)

        XCTAssertEqual(player.playbackQueue.map(\.id), ["B", "C"])
        XCTAssertEqual(player.currentQueueIndex, 1)
        XCTAssertEqual(player.currentSong?.id, "C")
    }

    func testRemoveQueueItemAfterCurrentLeavesCurrentUnchanged() async {
        let player = MusicPlayerService()
        let queue = songs(["A", "B", "C"])
        await player.play(queue[0], newQueue: queue) // current = A, index 0

        await player.removeQueueItem(at: 2)

        XCTAssertEqual(player.playbackQueue.map(\.id), ["A", "B"])
        XCTAssertEqual(player.currentQueueIndex, 0)
        XCTAssertEqual(player.currentSong?.id, "A")
    }

    func testRemoveCurrentQueueItemAdvancesToWhatTakesItsPlace() async {
        let player = MusicPlayerService()
        let queue = songs(["A", "B", "C"])
        await player.play(queue[1], newQueue: queue) // current = B, index 1

        await player.removeQueueItem(at: 1)

        XCTAssertEqual(player.playbackQueue.map(\.id), ["A", "C"])
        XCTAssertEqual(player.currentQueueIndex, 1)
        XCTAssertEqual(player.currentSong?.id, "C")
    }

    func testRemovingLastRemainingQueueItemStopsPlayback() async {
        let player = MusicPlayerService()
        let queue = songs(["A"])
        await player.play(queue[0], newQueue: queue)

        await player.removeQueueItem(at: 0)

        XCTAssertTrue(player.playbackQueue.isEmpty)
        XCTAssertEqual(player.currentQueueIndex, -1)
        XCTAssertNil(player.currentSong)
    }

    // MARK: - Queue editing: insertNext / appendToQueue

    func testInsertNextInsertsImmediatelyAfterCurrent() async {
        let player = MusicPlayerService()
        let queue = songs(["A", "B", "C"])
        await player.play(queue[0], newQueue: queue) // current = A, index 0

        player.insertNext(song("X"))

        XCTAssertEqual(player.playbackQueue.map(\.id), ["A", "X", "B", "C"])
        XCTAssertEqual(player.currentQueueIndex, 0)
    }

    func testAppendToQueueAddsAtEnd() async {
        let player = MusicPlayerService()
        let queue = songs(["A", "B"])
        await player.play(queue[0], newQueue: queue)

        player.appendToQueue(song("Z"))

        XCTAssertEqual(player.playbackQueue.map(\.id), ["A", "B", "Z"])
        XCTAssertEqual(player.currentQueueIndex, 0)
    }

    func testInsertNextOnEmptyQueueBecomesTheQueue() {
        let player = MusicPlayerService()
        player.insertNext(song("A"))
        XCTAssertEqual(player.playbackQueue.map(\.id), ["A"])
        XCTAssertEqual(player.currentQueueIndex, 0)
    }

    // MARK: - localFileResolver

    /// Writes a trivial-but-real file so `AVAudioFile(forReading:)` inside `loadAndPlay` can at
    /// least attempt to open it — the resolver contract only promises a *readable path*, not a
    /// decodable one, so `loadAndPlay` may still bail out after that point. What this covers is
    /// the part before that: the resolver gets invoked, and its returned path is written back
    /// into `currentSong`/the queue entry.
    private func makeTempFile(_ id: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(id)-\(UUID().uuidString).m4a")
        FileManager.default.createFile(atPath: url.path, contents: Data([0, 1, 2, 3]))
        return url
    }

    func testNextInvokesResolverAndRewritesCurrentSongPathWhenFileIsMissing() async {
        let player = MusicPlayerService()
        let queue = songs(["A", "B"])
        await player.play(queue[0], newQueue: queue) // current = A, index 0

        let resolvedURL = makeTempFile("B")
        var resolverCalls: [String] = []
        player.localFileResolver = { song in
            resolverCalls.append(song.id)
            var resolved = song
            resolved.path = resolvedURL.path
            return resolved
        }

        await player.next()

        XCTAssertEqual(resolverCalls, ["B"])
        XCTAssertEqual(player.currentSong?.id, "B")
        XCTAssertEqual(player.currentSong?.path, resolvedURL.path)
        XCTAssertEqual(player.playbackQueue[player.currentQueueIndex].path, resolvedURL.path)

        try? FileManager.default.removeItem(at: resolvedURL)
    }

    func testNextLeavesPathUnchangedWhenResolverReturnsNil() async {
        let player = MusicPlayerService()
        let queue = songs(["A", "B"])
        await player.play(queue[0], newQueue: queue) // current = A, index 0

        player.localFileResolver = { _ in nil }

        await player.next()

        XCTAssertEqual(player.currentSong?.id, "B")
        XCTAssertEqual(player.currentSong?.path, "/nonexistent/B.m4a")
    }

    func testNextSkipsResolverWhenFileAlreadyExists() async {
        let player = MusicPlayerService()
        let existingURL = makeTempFile("B")
        let queue = [song("A"), Song(id: "B", path: existingURL.path, title: "B")]
        await player.play(queue[0], newQueue: queue) // current = A, index 0

        var resolverCalled = false
        player.localFileResolver = { _ in
            resolverCalled = true
            return nil
        }

        await player.next() // advances to B, whose path already exists on disk

        XCTAssertFalse(resolverCalled)
        XCTAssertEqual(player.currentSong?.id, "B")
        XCTAssertEqual(player.currentSong?.path, existingURL.path)

        try? FileManager.default.removeItem(at: existingURL)
    }
}
