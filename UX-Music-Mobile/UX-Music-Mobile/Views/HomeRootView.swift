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
            miniPlayerStack
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
    }

    @ViewBuilder
    private var miniPlayerStack: some View {
        VStack(spacing: 0) {
            Divider()
                .overlay(Color.white.opacity(0.14))
            MiniPlayerView()
        }
        .frame(maxWidth: .infinity)
        .background(.bar)
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
    /// The 26.1 branch applies the *modifier* conditionally rather than returning an empty accessory
    /// when nothing is playing. The system draws the accessory's glass capsule as soon as the
    /// modifier is present, whatever the content is — an `EmptyView` and a zero-height `Color.clear`
    /// both leave a ~56pt empty capsule floating over the list (verified on the simulator). Applying
    /// the modifier at all is the only thing that controls whether the capsule exists.
    ///
    /// The cost is that toggling `isEnabled` re-creates the `TabView` subtree, so the gate must flip
    /// as rarely as possible — see `HomeRootView.showMiniPlayerAccessory`.
    @ViewBuilder
    func uxMusicTabMiniPlayer<Content: View>(
        isEnabled: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        if #available(iOS 26.1, *) {
            if isEnabled {
                self.tabViewBottomAccessory { content() }
            } else {
                self
            }
        } else {
            self.safeAreaInset(edge: .bottom, spacing: 0) {
                if isEnabled {
                    content()
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
