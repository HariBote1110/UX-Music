import SwiftUI

struct HomeRootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: MainTab = .library

    /// Deliberately does *not* also check `isNowPlayingSheetPresented`. Toggling this flips the
    /// accessory modifier on and off, which re-creates the whole `TabView` subtree (see
    /// `uxMusicTabMiniPlayer`), and Now Playing opens as a `fullScreenCover` that covers the mini
    /// player anyway — gating on it would rebuild every tab each time the user opened or closed it.
    /// As written it flips at most once per session, when the first song starts.
    private var showMiniPlayerAccessory: Bool {
        model.player.currentSong != nil
    }

    var body: some View {
        TabView(selection: $tab) {
            LazyTabRoot(isSelected: tab == .library) {
                LocalLibraryScreen()
            }
            .tabItem { Label("Library", systemImage: "music.note.list") }
            .tag(MainTab.library)

            LazyTabRoot(isSelected: tab == .remote) {
                RemoteLibraryScreen()
            }
            .tabItem { Label("Remote", systemImage: "wifi") }
            .tag(MainTab.remote)

            LazyTabRoot(isSelected: tab == .control) {
                RemoteControlScreen()
            }
            .tabItem { Label("Control", systemImage: "tv") }
            .tag(MainTab.control)

            LazyTabRoot(isSelected: tab == .settings) {
                SettingsScreen()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(MainTab.settings)
        }
        .uxMusicTabMiniPlayer(isEnabled: showMiniPlayerAccessory) {
            MiniPlayerView()
        }
        // fullScreenCover instead of sheet: the Now Playing screen is a full-screen
        // experience (like Apple Music). A sheet leaves system-injected top/bottom
        // margins that appear as solid-black bands against the ambient gradient.
        .fullScreenCover(
            isPresented: Binding(
                get: { model.isNowPlayingSheetPresented },
                set: { model.isNowPlayingSheetPresented = $0 }
            )
        ) {
            NowPlayingView()
                .environment(model)
        }
        // Desktop-pushed "sidecar" display (see `SidecarDirective`/`AppModel.startSidecarPolling`).
        // Bound to `isSidecarPresented` (not `sidecarActive` directly) so a local close-button
        // dismissal sticks until the desktop directive goes false→true again.
        .fullScreenCover(isPresented: Binding(
            get: { model.isSidecarPresented },
            set: { newValue in
                if !newValue { model.dismissSidecarLocally() }
            }
        )) {
            SidecarScreen()
                .environment(model)
        }
    }

}

// MARK: - Lazy tab roots

/// Builds the tab’s root only while it is selected so other tabs do not run `.task`, `onAppear`, or networking at launch.
private struct LazyTabRoot<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        if isSelected {
            content()
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Tab bar stacking

private extension View {
    /// iOS 26.1+: `tabViewBottomAccessory` stacks the bar above the tab bar. Earlier OS uses `safeAreaInset`.
    ///
    /// An earlier version of this modifier applied `.tabViewBottomAccessory` inside an `if isEnabled
    /// { self.tabViewBottomAccessory { … } } else { self }` branch, because rendering an `EmptyView`
    /// or a zero-height `Color.clear` *inside* an always-applied accessory still left a ~56pt empty
    /// glass capsule floating over the list (verified on the simulator) — the system drew the capsule
    /// as soon as the modifier was present, regardless of content. But that if/else swapped the
    /// `TabView`'s structural identity the first time `isEnabled` flipped false→true (first song
    /// played), so SwiftUI rebuilt the whole subtree and every tab's scroll position reset — see
    /// `progress/tab-accessory-scroll-reset.md`.
    ///
    /// The fix: iOS 26.1 also ships `tabViewBottomAccessory(isEnabled:content:)`, a single modifier
    /// call that toggles the accessory's visibility (no capsule when `isEnabled` is `false`) without
    /// restructuring the view tree — the `TabView` keeps one stable identity across the flip, so
    /// scroll position survives. Confirmed empirically: no empty capsule at idle launch (no song
    /// playing) on the simulator.
    @ViewBuilder
    func uxMusicTabMiniPlayer<Content: View>(
        isEnabled: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        if #available(iOS 26.1, *) {
            self.tabViewBottomAccessory(isEnabled: isEnabled) { content() }
        } else {
            // Pre-26.1 has no floating accessory, so the mini player is a plain bar pinned above
            // the tab bar and has to bring its own separator and material. On 26.1+ the system's
            // accessory already provides the glass; stacking `.bar` on top of it made the capsule
            // read as a heavy frosted slab.
            self.safeAreaInset(edge: .bottom, spacing: 0) {
                if isEnabled {
                    VStack(spacing: 0) {
                        Divider()
                            .overlay(Color.white.opacity(0.14))
                        content()
                    }
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                }
            }
        }
    }
}

private enum MainTab: Hashable {
    case library
    case remote
    case control
    case settings
}
