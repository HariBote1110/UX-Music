import SwiftUI

/// Watch-specific wrappers around the shared, target-agnostic `ShuffleModeIcon`/`RepeatModeIcon`
/// content views (`Core/ModeIconViews.swift`) — adds the tap frame/hit-target sizing and default
/// tint choices the Watch's transport row wants. See `ModeIconViews.swift`'s doc comment for the
/// desktop-parity background on why these icons are drawn as animated `Path`s rather than static
/// imagesets/SF Symbols.

/// Shuffle icon: replaces `Image("DesktopShuffleIcon")`. `iconSize` and `tapFrameSize` default to
/// the original fixed sizing (~20pt icon in a 36pt tap frame), but `WatchNowPlayingView`'s
/// `ViewThatFits` ladder passes smaller values on its more compact rungs so this row can shrink
/// along with the rest of the page.
struct WatchShuffleIcon: View {
    let isActive: Bool
    var iconSize: CGFloat = 20
    var tapFrameSize: CGFloat = 36

    var body: some View {
        ShuffleModeIcon(isActive: isActive, iconSize: iconSize)
            .frame(width: tapFrameSize, height: tapFrameSize)
            .contentShape(Rectangle())
    }
}

/// Repeat icon: replaces `Image("DesktopRepeatIcon")`. Keeps the existing "1" badge overlay for
/// `.one`, tinted like the active state. `iconSize`/`tapFrameSize` default as in `WatchShuffleIcon`
/// — see its doc comment.
struct WatchRepeatIcon: View {
    let repeatMode: WatchRepeatMode
    var iconSize: CGFloat = 20
    var tapFrameSize: CGFloat = 36

    var body: some View {
        RepeatModeIcon(repeatMode: repeatMode, iconSize: iconSize)
            .frame(width: tapFrameSize, height: tapFrameSize)
            .contentShape(Rectangle())
    }
}
