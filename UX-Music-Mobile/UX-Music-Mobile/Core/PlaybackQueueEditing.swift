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
}
