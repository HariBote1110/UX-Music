import SwiftUI
import WatchKit

/// Third page of the Watch app (Library ⇄ Now Playing ⇄ Queue & Volume — see `WatchRootView`'s
/// paged `TabView`): the system volume control at the top, and the currently playing queue below
/// it, mirroring the layout of watchOS's own Music app's volume/queue page. Rows reuse
/// `WatchSongRow` (shared with `WatchSongListView`) so the look matches the Library page exactly —
/// artwork, title/artist, and a speaker glyph on whichever song is current; tapping a row re-plays
/// `player.playbackQueue` starting at that song (the same queue, just repositioned) rather than
/// switching pages or replacing the queue with something new.
struct WatchQueueVolumeView: View {
    @EnvironmentObject private var player: WatchAudioPlayerService

    var body: some View {
        List {
            Section("Volume") {
                SystemVolumeControl()
                    .frame(height: 28)
            }

            Section {
                if player.playbackQueue.isEmpty {
                    Text("The queue is empty")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(player.playbackQueue) { meta in
                        WatchSongRow(meta: meta, queue: player.playbackQueue)
                    }
                }
            }
        }
        .navigationTitle("Queue")
    }
}

/// SwiftUI wrapper around `WKInterfaceVolumeControl`, watchOS's system volume UI — the same control
/// Apple's own Music/Podcasts apps show. There is no plain-SwiftUI audio volume view on watchOS (as
/// of this SDK), so `WKInterfaceObjectRepresentable` (the WatchKit analogue of `UIViewRepresentable`)
/// is the only way to surface it. `.local` targets the Watch's own output, matching how this app
/// always plays back through the Watch's own `AVAudioSession` (see `WatchAudioPlayerService`) rather
/// than routing audio through the paired iPhone.
///
/// Target-internal (not `private`) so `WatchNowPlayingView` can reuse the same control for its
/// Digital Crown volume row — see that view's doc comment for why the Crown drives volume rather
/// than seeking there.
struct SystemVolumeControl: WKInterfaceObjectRepresentable {
    /// When `true`, calls `WKInterfaceVolumeControl.focus()` so the Digital Crown drives it
    /// immediately without requiring a tap first. Used by `WatchNowPlayingView`, where the Crown's
    /// sole job is now volume; left `false` here on the Queue & Volume page, where the control sits
    /// above a scrollable queue list the Crown should scroll by default.
    ///
    /// **Must only be `true` while the control's own page is genuinely the one on screen** — see
    /// `WatchNowPlayingView.hiddenCrownVolumeControl`'s doc comment. `WatchRootView`'s paged
    /// `TabView` keeps adjacent pages mounted, so this cannot safely be a constant `true` for a page
    /// that isn't always the selected one: calling `focus()` on a `WKInterfaceVolumeControl` that
    /// isn't part of the currently-front interface controller sends SwiftUI's AttributeGraph into a
    /// self-referential update cycle that pegs the main thread indefinitely (confirmed by sampling —
    /// see `progress/watch-ui-redesign.md`), taking the page swipe and the Digital Crown down with
    /// it. Callers must derive this from the same page-selection state the `TabView` uses.
    var autoFocusesCrown: Bool = false
    /// Bumped by the caller each time it wants focus re-requested — typically on each transition to
    /// the control's page actually becoming selected (not just "appeared"; see `autoFocusesCrown`'s
    /// doc comment for why the distinction matters) rather than only once for the view's whole
    /// lifetime, since Crown focus is contested (paging to another tab can hand it to a different
    /// focusable element, and it does not automatically return here on its own).
    /// `updateWKInterfaceObject` calls `focus()` only when this value has changed since the last
    /// call, so routine SwiftUI update passes (e.g. the 0.5s playback-position tick on
    /// `WatchNowPlayingView`) don't each re-trigger it.
    var refocusTrigger: Int = 0

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        WKInterfaceVolumeControl(origin: .local)
    }

    func updateWKInterfaceObject(_ wkInterfaceObject: WKInterfaceVolumeControl, context: Context) {
        guard autoFocusesCrown, context.coordinator.lastFocusedTrigger != refocusTrigger else { return }
        context.coordinator.lastFocusedTrigger = refocusTrigger
        wkInterfaceObject.focus()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Tracks the `refocusTrigger` value `focus()` was last called for, so it re-fires only when
    /// the caller bumps the trigger (typically on page appearance) rather than on every SwiftUI
    /// update pass.
    final class Coordinator {
        var lastFocusedTrigger: Int?
    }
}

#Preview {
    let library = WatchLocalLibrary()
    let player = WatchAudioPlayerService(library: library)
    WatchQueueVolumeView()
        .environmentObject(library)
        .environmentObject(player)
}
