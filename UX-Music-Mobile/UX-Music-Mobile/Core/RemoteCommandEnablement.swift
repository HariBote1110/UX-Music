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
