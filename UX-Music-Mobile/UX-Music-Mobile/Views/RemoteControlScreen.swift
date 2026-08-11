import SwiftUI

/// Remote Control tab: mirrors the desktop transport (`/v1/remote/state` + `/v1/remote/command`) using the
/// same visual language as `NowPlayingView` (ambient background, rounded artwork card, transport
/// row) rather than a bare prototype-style layout.
/// Selects which device the transport controls below actually operate on (Phase 3-1 Mobile side,
/// "この iPhone" vs a discovered Apple TV `_uxmusic-remote._tcp` receiver). Session-only — no
/// persistence across app launches (per plan §3-1's picker UX scope).
enum RemoteControlTarget: Hashable {
    case thisIPhone
    case tv(TVRemoteTarget)
}

struct RemoteControlScreen: View {
    @Environment(AppModel.self) private var model
    @StateObject private var tvDiscovery = TVRemoteDiscoveryService()
    @State private var selectedTarget: RemoteControlTarget = .thisIPhone
    @State private var desktopState: [String: Any] = [:]
    @State private var errorMessage: String?
    @State private var pollTask: Task<Void, Never>?
    /// True after at least one successful `/v1/remote/state` fetch (matches Flutter “stale state + error” UX).
    @State private var hasReceivedState = false

    /// The client commands/state polling actually go through — the Host's failover-aware client
    /// when `selectedTarget == .thisIPhone`, or a direct client against the TV's own receiver
    /// otherwise. Reuses the exact same `RemoteAPIClient` type/`sendCommand`/`fetchState` calls
    /// either way; only the base URL + token differ (§3-1: "reuse the existing remote-control
    /// client code pattern").
    private var tvClient: RemoteAPIClient? {
        guard case .tv(let target) = selectedTarget else { return nil }
        return RemoteAPIClient(baseURLString: target.baseURLString, token: target.token)
    }

    var body: some View {
        NavigationStack {
            Group {
                if !hasReceivedState, errorMessage != nil {
                    unreachableView
                } else {
                    controlsView
                }
            }
            // NOTE: the ambient background must be attached via `.background()` rather than
            // stacked as a ZStack sibling. `NowPlayingAmbientBackground` internally calls
            // `.ignoresSafeArea()`, and a ZStack sizes itself to the *largest* child — if the
            // background were a sibling, its full-screen size would dominate the ZStack's layout
            // size and the transport controls below would lay out against the un-inset screen
            // height, pushing them underneath the mini-player/tab-bar footer overlay instead of
            // the safe area actually left available by `HomeRootView`'s `.safeAreaInset`/
            // `tabViewBottomAccessory`. `.background()` paints behind the primary content without
            // affecting its layout size, so the footer inset is respected correctly.
            .background {
                NowPlayingAmbientBackground(palette: nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Extra manual clearance ON TOP of the system-provided safe area inset.
            // `HomeRootView` uses `tabViewBottomAccessory` (iOS 26.1+) to host the mini-player
            // pill above the tab bar. That accessory container always reserves its own pill-
            // shaped region — even when `MiniPlayerView` renders `EmptyView` because no local
            // song is playing — but its true rendered height is system chrome that this view
            // cannot introspect via GeometryReader (there is nothing of ours to measure when the
            // content is empty). The automatic safe-area inset the system hands down to tab
            // content under-reports this reserved height by roughly a dozen points, so the
            // transport row's white play button still dipped under the pill's top edge. This
            // fixed buffer closes that residual gap; it only adds space on top of whatever inset
            // the system already provides, so it degrades gracefully across OS versions.
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 44)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                startPolling()
                tvDiscovery.start()
            }
            .onDisappear {
                pollTask?.cancel()
                pollTask = nil
                tvDiscovery.stop()
            }
        }
    }

    private var unreachableView: some View {
        ContentUnavailableView {
            Label("Desktop unreachable", systemImage: "wifi.slash")
                .foregroundStyle(.white)
        } description: {
            Text("Check that UX Music is running on the desktop over Wi-Fi.")
                .foregroundStyle(.white.opacity(0.55))
        }
        .tint(.white)
    }

    private var controlsView: some View {
        let position = doubleValue(desktopState["position"])
        let duration = doubleValue(desktopState["duration"])
        let title = desktopState["title"] as? String ?? ""
        let artist = desktopState["artist"] as? String ?? ""
        let album = desktopState["album"] as? String ?? ""

        return VStack(spacing: 0) {
            HStack {
                connectionChip
                Spacer()
                RemoteControlTargetPicker(selected: selectedTarget, tvTargets: tvDiscovery.targets) { target in
                    switchTarget(target)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer(minLength: 12)

            RemoteArtworkCard(title: title, artist: artist, album: album)
                .padding(.horizontal, 28)

            Spacer(minLength: 28)

            VStack(spacing: 10) {
                Text(title.isEmpty ? "No track" : title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text(artist)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 24)

            if duration > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    SeekSlider(position: position, duration: duration) { v in
                        Task { await send("seek", value: v) }
                    }
                    .tint(.white)

                    HStack {
                        Text(formatTime(position))
                        Spacer()
                        Text(formatTime(duration))
                    }
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 24)

                Spacer(minLength: 20)
            }

            transportRow
                .padding(.bottom, 8)

            if let errorMessage, !desktopState.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
            }

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 4)
    }

    private var connectionChip: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(errorMessage == nil ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(errorMessage == nil ? "Connected" : "Reconnecting…")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.ultraThinMaterial))
    }

    private var transportRow: some View {
        let playing = desktopState["playing"] as? Bool ?? false
        return HStack(spacing: 44) {
            transportIconButton(systemName: "backward.fill", size: 22) {
                Task { await send("prev") }
            }
            .accessibilityLabel("Previous track")

            Button {
                Task { await send("toggle") }
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 80, height: 80)
                    .background(
                        Circle()
                            .fill(.white)
                            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playing ? "Pause" : "Play")

            transportIconButton(systemName: "forward.fill", size: 22) {
                Task { await send("next") }
            }
            .accessibilityLabel("Next track")
        }
    }

    private func transportIconButton(systemName: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func doubleValue(_ any: Any?) -> Double {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        return 0
    }

    private func formatTime(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "\(m):\(String(format: "%02d", s))"
    }

    private func send(_ action: String, value: Double? = nil) async {
        do {
            if let tvClient {
                _ = try await tvClient.sendCommand(action: action, value: value)
            } else {
                _ = try await model.withFailover { try await $0.sendCommand(action: action, value: value) }
            }
            await pollOnce()
        } catch {
            await MainActor.run { errorMessage = "Command failed: \(error.localizedDescription)" }
        }
    }

    private func pollOnce() async {
        do {
            let s: [String: Any]
            if let tvClient {
                s = try await tvClient.fetchState()
            } else {
                s = try await model.withFailover { try await $0.fetchState() }
            }
            await MainActor.run {
                hasReceivedState = true
                desktopState = s
                errorMessage = nil
            }
        } catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await pollOnce()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Switching targets clears the last-known state so the transport row doesn't briefly show
    /// the previous target's stale track/position before the next poll lands.
    private func switchTarget(_ target: RemoteControlTarget) {
        selectedTarget = target
        hasReceivedState = false
        desktopState = [:]
        errorMessage = nil
        Task { await pollOnce() }
    }
}

/// "この iPhone" vs discovered Apple TV receivers (§3-1). A plain menu rather than a full screen —
/// this mirrors the existing Remote tab's compact chip-style status affordances
/// (`connectionChip`) rather than introducing a new navigation pattern.
private struct RemoteControlTargetPicker: View {
    let selected: RemoteControlTarget
    let tvTargets: [TVRemoteTarget]
    let onSelect: (RemoteControlTarget) -> Void

    private var label: String {
        switch selected {
        case .thisIPhone: return String(localized: "This iPhone")
        case .tv(let target): return target.displayName
        }
    }

    var body: some View {
        Menu {
            Button(String(localized: "This iPhone")) { onSelect(.thisIPhone) }
            if !tvTargets.isEmpty {
                Divider()
                ForEach(tvTargets) { target in
                    Button(target.displayName) { onSelect(.tv(target)) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                Text(label)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(.ultraThinMaterial))
        }
    }

    private var iconName: String {
        switch selected {
        case .thisIPhone: return "iphone"
        case .tv: return "appletv.fill"
        }
    }
}

/// Looks up the playing track's artwork by title/artist against the Remote library (`/v1/remote/state`
/// has no `artworkId`), and falls back to a placeholder card matching `NowPlayingArtworkBlock`'s
/// styling when the track cannot be resolved.
private struct RemoteArtworkCard: View {
    @Environment(AppModel.self) private var model
    let title: String
    let artist: String
    let album: String

    private var matchedSong: Song? {
        guard case .loaded(let songs) = model.libraryState, !title.isEmpty else { return nil }
        return songs.first { song in
            song.title == title && song.artist == artist
        } ?? songs.first { song in
            song.title == title
        }
    }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 340)
            .overlay {
                if let song = matchedSong, !song.artworkId.isEmpty {
                    ArtworkImageView(
                        artworkId: song.artworkId,
                        urlString: model.artworkURL(for: song.artworkId),
                        cornerRadius: 20,
                        size: nil
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.55), radius: 32, y: 18)
            .task {
                if case .idle = model.libraryState {
                    await model.refreshLibrary()
                }
            }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.14), Color(white: 0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "desktopcomputer")
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.28))
        }
    }
}

/// Slider that sends seek on drag end (avoids spamming the server).
private struct SeekSlider: View {
    let position: Double
    let duration: Double
    var onSeekEnd: (Double) -> Void

    @State private var local: Double = 0
    @State private var dragging = false

    var body: some View {
        Slider(
            value: Binding(
                get: { dragging ? local : position },
                set: { local = $0 }
            ),
            in: 0 ... max(duration, 0.001),
            onEditingChanged: { isEditing in
                if isEditing {
                    if !dragging {
                        local = position
                        dragging = true
                    }
                } else {
                    dragging = false
                    onSeekEnd(local)
                }
            }
        )
    }
}
