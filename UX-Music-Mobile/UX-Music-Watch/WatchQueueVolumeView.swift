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
            Section("音量") {
                SystemVolumeControl()
                    .frame(height: 28)
            }

            Section {
                if player.playbackQueue.isEmpty {
                    Text("キューは空です")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(player.playbackQueue) { meta in
                        WatchSongRow(meta: meta, queue: player.playbackQueue)
                    }
                }
            }
        }
        .navigationTitle("キュー")
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
    /// When `true`, calls `WKInterfaceVolumeControl.focus()` once after the control first appears so
    /// the Digital Crown drives it immediately without requiring a tap first. Used by
    /// `WatchNowPlayingView`, where the Crown's sole job is now volume; left `false` here on the
    /// Queue & Volume page, where the control sits above a scrollable queue list the Crown should
    /// scroll by default.
    var autoFocusesCrown: Bool = false

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        WKInterfaceVolumeControl(origin: .local)
    }

    func updateWKInterfaceObject(_ wkInterfaceObject: WKInterfaceVolumeControl, context: Context) {
        guard autoFocusesCrown, !context.coordinator.hasFocused else { return }
        context.coordinator.hasFocused = true
        wkInterfaceObject.focus()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Tracks whether `focus()` has already been requested, so it fires once (on first appearance)
    /// rather than on every SwiftUI update pass.
    final class Coordinator {
        var hasFocused = false
    }
}

#Preview {
    let library = WatchLocalLibrary()
    let player = WatchAudioPlayerService(library: library)
    WatchQueueVolumeView()
        .environmentObject(library)
        .environmentObject(player)
}
