import SwiftUI

struct HomeRootView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: MainTab = .library

    private var showMiniPlayerAccessory: Bool {
        !model.isNowPlayingSheetPresented && model.player.currentSong != nil
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
        .sheet(
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
    @ViewBuilder
    func uxMusicTabMiniPlayer<Content: View>(
        isEnabled: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        if #available(iOS 26.1, *) {
            self.tabViewBottomAccessory {
                if isEnabled {
                    content()
                }
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
