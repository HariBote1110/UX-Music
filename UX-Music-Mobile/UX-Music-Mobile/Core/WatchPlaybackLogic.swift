import Foundation
import MediaPlayer

/// Pure queue-navigation arithmetic shared by the Watch player service and its tests. Kept free of
/// `AVPlayer`/WatchKit so the wrap-around and "restart vs. skip back" rules are unit-testable
/// without a real playback session.
///
/// This type has iOS and watchOS target membership, mirroring `WatchTransfer.swift`.
enum WatchQueueNavigation {
    /// Index of the next track, wrapping to the start of the queue. `0` when the queue is empty
    /// (caller is expected to guard on `count == 0` separately if that should be a no-op).
    static func nextIndex(current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (current + 1) % count
    }

    /// Index of the previous track, wrapping to the end of the queue.
    static func previousIndex(current: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return (current - 1 + count) % count
    }

    /// Standard media-player UX: pressing "previous" more than `threshold` seconds into a track
    /// restarts the current track instead of jumping back a track.
    static func shouldRestartOnPrevious(position: Double, threshold: Double = 3) -> Bool {
        position > threshold
    }
}

/// Pure clamping for Digital Crown-driven seeking, so the "never seek past the ends of the track"
/// rule is unit-testable independent of `AVPlayer`.
enum WatchSeekLogic {
    /// Clamps a raw seek target (e.g. from `.digitalCrownRotation`) to `0...duration`. Returns `0`
    /// for a non-positive duration (nothing sensible to seek to).
    static func clampedPosition(_ raw: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(raw, 0), duration)
    }
}

/// Builds the `MPNowPlayingInfoCenter` payload from Watch playback state, kept as a pure function so
/// the key/value mapping is unit-testable without `MPNowPlayingInfoCenter.default()` (which cannot
/// be observed from an XCTest target).
enum WatchNowPlayingInfoBuilder {
    static func buildInfo(for song: WatchTransferMeta?, isPlaying: Bool, position: Double) -> [String: Any] {
        guard let song else { return [:] }
        return [
            MPMediaItemPropertyTitle: song.displayTitle,
            MPMediaItemPropertyArtist: song.displayArtist,
            MPMediaItemPropertyAlbumTitle: song.displayAlbum,
            MPMediaItemPropertyPlaybackDuration: song.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
    }
}
