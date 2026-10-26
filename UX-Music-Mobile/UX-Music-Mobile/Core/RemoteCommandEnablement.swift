import Foundation

/// Maps playback state to Now Playing remote command enablement.
///
/// tvOS maps the single Siri Remote play/pause button to whichever of `playCommand` /
/// `pauseCommand` is enabled, so play and pause must never both be enabled at once
/// (see `MusicPlayerService.updateNowPlayingCentre()`).
enum RemoteCommandEnablement {
    struct State: Equatable {
        let playEnabled: Bool
        let pauseEnabled: Bool
        let toggleEnabled: Bool
    }

    static func state(hasSong: Bool, isPlaying: Bool) -> State {
        State(
            playEnabled: hasSong && !isPlaying,
            pauseEnabled: hasSong && isPlaying,
            toggleEnabled: hasSong
        )
    }
}

/// What was last pushed to `MPNowPlayingInfoCenter`, used to suppress redundant periodic
/// republishing. iOS interpolates elapsed time itself from `ElapsedPlaybackTime` + `PlaybackRate`,
/// so a rewrite (an IPC to the media server plus a lock screen / Watch redraw) is only needed when
/// something other than the expected elapsed advance changed.
struct NowPlayingPublication: Equatable {
    var songId: String?
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var isPlaying: Bool
    var hasArtwork: Bool
    var skipEnabled: Bool
    var elapsed: Double
    var publishedAt: Date

    /// Largest tolerated gap between the elapsed time iOS would extrapolate and the real one.
    static let elapsedDriftTolerance: TimeInterval = 1.0

    static func shouldPublish(previous: NowPlayingPublication?, next: NowPlayingPublication, now: Date) -> Bool {
        guard let previous else { return true }
        guard previous.songId == next.songId,
              previous.title == next.title,
              previous.artist == next.artist,
              previous.album == next.album,
              previous.duration == next.duration,
              previous.isPlaying == next.isPlaying,
              previous.hasArtwork == next.hasArtwork,
              previous.skipEnabled == next.skipEnabled
        else { return true }
        let rate = previous.isPlaying ? 1.0 : 0.0
        let expected = previous.elapsed + now.timeIntervalSince(previous.publishedAt) * rate
        return abs(next.elapsed - expected) > elapsedDriftTolerance
    }
}
