import Foundation

/// `Song`-queue overload of `PlaybackShuffleLogic.applyShuffle`, kept in this iOS-only file (not
/// `WatchPlaybackLogic.swift`, which also has watchOS target membership where `Song`/`Models` is
/// not available) so `MusicPlayerService`'s `[Song]` queue can reuse the same "keep the
/// currently-playing song at the front" shuffle rule as the Watch's `[WatchTransferMeta]` queue.
extension PlaybackShuffleLogic {
    static func applyShuffle(
        queue: [Song],
        shuffledIndices: [Int],
        currentId: String?
    ) -> [Song] {
        guard shuffledIndices.count == queue.count else { return queue }
        var shuffled = shuffledIndices.map { queue[$0] }
        guard let currentId, let index = shuffled.firstIndex(where: { $0.id == currentId }) else {
            return shuffled
        }
        let current = shuffled.remove(at: index)
        shuffled.insert(current, at: 0)
        return shuffled
    }
}

/// Pure index arithmetic for editing `MusicPlayerService`'s playback queue (move / remove) while
/// keeping `currentIndex` pointing at the same song across the mutation. Kept free of
/// `MusicPlayerService`/`AVAudioEngine` so the edge cases (removing the currently-playing item,
/// removing the last item, moving the currently-playing item) are unit-testable without a real
/// playback session — this is where queue-editing bugs actually live.
enum PlaybackQueueEditing {
    /// Removes the element at `from` and re-inserts it so it ends up at index `to` in the
    /// resulting array (i.e. `to` is the element's final index, not an insertion point measured
    /// against the pre-removal array). Out-of-range `from` is a no-op; `to` is clamped into the
    /// resulting array's bounds.
    static func moveElement<T>(in array: [T], from: Int, to: Int) -> [T] {
        guard array.indices.contains(from) else { return array }
        var copy = array
        let item = copy.remove(at: from)
        let clampedTo = min(max(0, to), copy.count)
        copy.insert(item, at: clampedTo)
        return copy
    }

    /// Where `currentIndex` ends up after `moveElement(from:to:)` reorders the queue — needed
    /// because moving an *other* song across the currently-playing one shifts its index by one,
    /// even though playback itself is untouched.
    static func currentIndexAfterMoving(from: Int, to: Int, currentIndex: Int) -> Int {
        guard from != to else { return currentIndex }
        if currentIndex == from {
            return to
        }
        if from < currentIndex, currentIndex <= to {
            return currentIndex - 1
        }
        if to <= currentIndex, currentIndex < from {
            return currentIndex + 1
        }
        return currentIndex
    }

    /// Where `currentIndex` ends up after removing `removedIndex` from a queue of `countBefore`
    /// items — `nil` when the removal empties the queue entirely (caller should stop playback).
    /// When the currently-playing item itself is removed, the index is left pointing at "what takes
    /// its place" (the item that slides into the vacated slot), clamped to the new last index when
    /// the removed item was at the end of the queue.
    static func currentIndexAfterRemoving(removedIndex: Int, currentIndex: Int, countBefore: Int) -> Int? {
        guard countBefore > 0, (0 ..< countBefore).contains(removedIndex) else { return currentIndex }
        let countAfter = countBefore - 1
        guard countAfter > 0 else { return nil }
        if removedIndex < currentIndex {
            return currentIndex - 1
        }
        if removedIndex == currentIndex {
            return min(currentIndex, countAfter - 1)
        }
        return currentIndex
    }

    /// Stable `ForEach` row identity for a list of (possibly repeating) ids, e.g. song ids in a
    /// playback queue. Keying a row purely on its array offset (as the Up next panel used to)
    /// means any removal or reorder shifts the offsets — and hence the ids — of every subsequent
    /// row, so SwiftUI cannot tell they're the "same" row and tears down/rebuilds them instead of
    /// animating a clean move or delete. That teardown-and-rebuild is what reads as stale content
    /// briefly flashing during the transition.
    ///
    /// Each returned id is `"<id>#<occurrence>"`, where `occurrence` counts how many earlier
    /// entries in the array share that id. This keeps a row's identity fixed across edits that
    /// don't touch its own entry — reordering or removing *other* rows never changes it — and only
    /// shifts when an earlier *duplicate* of the same id is removed, in which case the surviving
    /// copy simply inherits the identity the removed one used to have (consistent, not stale).
    static func occurrenceIdentities(for ids: [String]) -> [String] {
        var seenCounts: [String: Int] = [:]
        return ids.map { id in
            let occurrence = seenCounts[id, default: 0]
            seenCounts[id] = occurrence + 1
            return "\(id)#\(occurrence)"
        }
    }

    // MARK: - Shuffle bookkeeping
    //
    // While shuffle is on, `queue` is the shuffled order, `originalQueue` is the order to restore
    // when shuffle is turned off, and `origins[i]` is the index in `originalQueue` of `queue[i]`.
    // Origins make every edit exact even when the same song appears more than once. If `origins`
    // ever falls out of step with `queue` (count mismatch), the helpers fall back to id-based
    // behaviour and clear `origins` rather than crashing.

    /// The unshuffled order and the per-entry origins that shuffle-on edits must keep in step.
    struct ShuffleBookkeeping<T> {
        var originalQueue: [T]
        var origins: [Int]
    }

    /// The shuffled order for `queue`, as indices into `queue`. Uses the same reordering as
    /// `PlaybackShuffleLogic.applyShuffle`: the first entry with `currentId` is moved to the front.
    /// `shuffledIndices` is returned unchanged when its count does not match `queue`.
    static func pinnedShuffleOrder<T>(
        queue: [T],
        shuffledIndices: [Int],
        currentId: String?,
        id: (T) -> String
    ) -> [Int] {
        guard shuffledIndices.count == queue.count else { return Array(queue.indices) }
        var order = shuffledIndices
        guard let currentId, let position = order.firstIndex(where: { id(queue[$0]) == currentId }) else {
            return order
        }
        let current = order.remove(at: position)
        order.insert(current, at: 0)
        return order
    }

    /// Bookkeeping after removing the entry at `removedIndex` of the pre-removal `queue`. The
    /// original copy named by that entry's origin is removed, and origins above it shift down.
    static func bookkeepingAfterRemoving<T>(
        queue: [T],
        state: ShuffleBookkeeping<T>,
        removedIndex: Int,
        id: (T) -> String
    ) -> ShuffleBookkeeping<T> {
        guard queue.indices.contains(removedIndex) else { return state }
        let inStep = state.origins.count == queue.count
        if inStep, state.origins.indices.contains(removedIndex) {
            let origin = state.origins[removedIndex]
            if state.originalQueue.indices.contains(origin) {
                var originalQueue = state.originalQueue
                originalQueue.remove(at: origin)
                var origins = state.origins
                origins.remove(at: removedIndex)
                origins = origins.map { $0 > origin ? $0 - 1 : $0 }
                return ShuffleBookkeeping(originalQueue: originalQueue, origins: origins)
            }
        }
        return removeFirstById(id(queue[removedIndex]), from: state.originalQueue, id: id)
    }

    /// Bookkeeping after appending `item` to `queue`. The new entry's origin is the end of the
    /// original order.
    static func bookkeepingAfterAppending<T>(
        queue: [T],
        state: ShuffleBookkeeping<T>,
        item: T
    ) -> ShuffleBookkeeping<T> {
        var originalQueue = state.originalQueue
        originalQueue.append(item)
        guard state.origins.count == queue.count else {
            return ShuffleBookkeeping(originalQueue: originalQueue, origins: [])
        }
        return ShuffleBookkeeping(originalQueue: originalQueue, origins: state.origins + [originalQueue.count - 1])
    }

    /// Bookkeeping after inserting `item` immediately after the entry at `currentIndex` of the
    /// pre-insert `queue`. The copy goes right after the current song's origin in the original
    /// order. If the current song cannot be located, `item` is appended to the original order.
    static func bookkeepingAfterInsertingNext<T>(
        queue: [T],
        state: ShuffleBookkeeping<T>,
        currentIndex: Int,
        item: T,
        id: (T) -> String
    ) -> ShuffleBookkeeping<T> {
        guard queue.indices.contains(currentIndex) else {
            return bookkeepingAfterAppending(queue: queue, state: state, item: item)
        }
        let inStep = state.origins.count == queue.count
        if inStep, state.origins.indices.contains(currentIndex) {
            let position = state.origins[currentIndex] + 1
            if position <= state.originalQueue.count {
                var originalQueue = state.originalQueue
                originalQueue.insert(item, at: position)
                var origins = state.origins.map { $0 >= position ? $0 + 1 : $0 }
                origins.insert(position, at: currentIndex + 1)
                return ShuffleBookkeeping(originalQueue: originalQueue, origins: origins)
            }
        }
        return insertAfterFirstById(id(queue[currentIndex]), item: item, into: state.originalQueue, id: id)
    }

    /// Bookkeeping after moving the entry at `from` to `to` in `queue`. Only the shuffled order
    /// changes; `originalQueue` is left alone, so turning shuffle off restores the original order.
    static func bookkeepingAfterMoving<T>(
        queue: [T],
        state: ShuffleBookkeeping<T>,
        from: Int,
        to: Int
    ) -> ShuffleBookkeeping<T> {
        guard state.origins.count == queue.count else { return state }
        return ShuffleBookkeeping(
            originalQueue: state.originalQueue,
            origins: moveElement(in: state.origins, from: from, to: to)
        )
    }

    /// Index in `originalQueue` of the current song (`queue[currentIndex]`), used when shuffle is
    /// turned off. Falls back to the first copy with `currentId` when origins are out of step.
    static func originalIndexOfCurrent<T>(
        queue: [T],
        state: ShuffleBookkeeping<T>,
        currentIndex: Int,
        currentId: String,
        id: (T) -> String
    ) -> Int? {
        if state.origins.count == queue.count, state.origins.indices.contains(currentIndex) {
            let origin = state.origins[currentIndex]
            if state.originalQueue.indices.contains(origin), id(state.originalQueue[origin]) == currentId {
                return origin
            }
        }
        return state.originalQueue.firstIndex(where: { id($0) == currentId })
    }

    /// Position in the shuffled queue of the entry whose origin is `originIndex`, or `nil`.
    static func shuffledIndex(ofOriginal originIndex: Int, origins: [Int]) -> Int? {
        origins.firstIndex(of: originIndex)
    }

    // MARK: - Id-based fallbacks

    private static func removeFirstById<T>(_ target: String, from originalQueue: [T], id: (T) -> String) -> ShuffleBookkeeping<T> {
        var copy = originalQueue
        if let index = copy.firstIndex(where: { id($0) == target }) {
            copy.remove(at: index)
        }
        return ShuffleBookkeeping(originalQueue: copy, origins: [])
    }

    private static func insertAfterFirstById<T>(
        _ current: String,
        item: T,
        into originalQueue: [T],
        id: (T) -> String
    ) -> ShuffleBookkeeping<T> {
        var copy = originalQueue
        if let index = copy.firstIndex(where: { id($0) == current }) {
            copy.insert(item, at: index + 1)
        } else {
            copy.append(item)
        }
        return ShuffleBookkeeping(originalQueue: copy, origins: [])
    }
}
