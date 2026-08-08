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
private struct SystemVolumeControl: WKInterfaceObjectRepresentable {
    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        WKInterfaceVolumeControl(origin: .local)
    }

    func updateWKInterfaceObject(_ wkInterfaceObject: WKInterfaceVolumeControl, context: Context) {}
}

#Preview {
    let library = WatchLocalLibrary()
    let player = WatchAudioPlayerService(library: library)
    WatchQueueVolumeView()
        .environmentObject(library)
        .environmentObject(player)
}
