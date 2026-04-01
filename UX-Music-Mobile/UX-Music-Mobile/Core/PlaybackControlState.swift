import AVFoundation

/// Maps `AVPlayer` time-control state to transport UI (mini player, now playing).
enum PlaybackControlState {
    /// `true` when the user should see a pause control (playback requested, including while buffering).
    static func showsPauseButton(timeControlStatus: AVPlayer.TimeControlStatus, rate: Float) -> Bool {
        switch timeControlStatus {
        case .playing, .waitingToPlayAtSpecifiedRate:
            return true
        case .paused:
            return rate > 0.01
        @unknown default:
            return rate > 0.01
        }
    }
}
