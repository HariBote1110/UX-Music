import SwiftUI

struct RemoteControlScreen: View {
    @Environment(AppModel.self) private var model
    @State private var desktopState: [String: Any] = [:]
    @State private var errorMessage: String?
    @State private var pollTask: Task<Void, Never>?
    /// True after at least one successful `/wear/state` fetch (matches Flutter “stale state + error” UX).
    @State private var hasReceivedState = false

    var body: some View {
        NavigationStack {
            Group {
                if !hasReceivedState, errorMessage != nil {
                    unreachableView
                } else {
                    controlsView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle("Remote Control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(red: 0.11, green: 0.11, blue: 0.12), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear { startPolling() }
            .onDisappear {
                pollTask?.cancel()
                pollTask = nil
            }
        }
    }

    private var unreachableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("Desktop unreachable")
                .foregroundStyle(.secondary)
        }
    }

    private var controlsView: some View {
        let playing = desktopState["playing"] as? Bool ?? false
        let position = doubleValue(desktopState["position"])
        let duration = doubleValue(desktopState["duration"])
        let title = desktopState["title"] as? String ?? ""
        let artist = desktopState["artist"] as? String ?? ""

        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Circle()
                    .fill(errorMessage == nil ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(errorMessage == nil ? "Connected" : "Reconnecting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 32)

            Image(systemName: "desktopcomputer")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)

            Text(title.isEmpty ? "No track" : title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(1)
            Text(artist)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .padding(.top, 4)

            if duration > 0 {
                SeekSlider(position: position, duration: duration) { v in
                    Task {
                        _ = try? await model.client().sendCommand(action: "seek", value: v)
                        await pollOnce()
                    }
                }
                .padding(.top, 24)

                HStack {
                    Text(formatTime(position))
                    Spacer()
                    Text(formatTime(duration))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }

            HStack(spacing: 24) {
                Button {
                    Task { await send("prev") }
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 38))
                }
                Button {
                    Task { await send("toggle") }
                } label: {
                    Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 72))
                }
                Button {
                    Task { await send("next") }
                } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 38))
                }
            }
            .foregroundStyle(.primary)
            .padding(.top, 24)

            if let errorMessage, !desktopState.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
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

    private func send(_ action: String) async {
        do {
            _ = try await model.client().sendCommand(action: action, value: nil)
            await pollOnce()
        } catch {
            await MainActor.run { errorMessage = "Command failed: \(error.localizedDescription)" }
        }
    }

    private func pollOnce() async {
        do {
            let s = try await model.client().fetchState()
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
