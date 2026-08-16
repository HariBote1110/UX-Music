import AVFoundation
import SwiftUI

/// Observes `AVAudioSession.sharedInstance().outputVolume` via KVO so `WatchNowPlayingView` can
/// show a transient volume HUD when the Digital Crown (via the hidden `SystemVolumeControl`)
/// changes the system volume. watchOS has no `MPVolumeView`-style notification for this the way
/// iOS does, so KVO on `outputVolume` (which the Apple docs mark as KVO-observable) is the only
/// practical way to react to Crown-driven volume changes here.
@MainActor
final class WatchVolumeObserver: NSObject, ObservableObject {
    @Published private(set) var level: Float

    private var observation: NSKeyValueObservation?

    override init() {
        let session = AVAudioSession.sharedInstance()
        level = session.outputVolume
        super.init()
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let newValue = change.newValue else { return }
            Task { @MainActor in
                self?.level = newValue
            }
        }
    }

    deinit {
        observation?.invalidate()
    }
}

/// Transient macOS-style vertical volume overlay (the pre-Tahoe/Sequoia volume OSD): a vertical
/// rounded gauge with a speaker glyph at the bottom, filling from the bottom to the current level.
/// Drawn as the top layer of `WatchNowPlayingView`'s `ZStack` so it floats over the page content
/// without affecting layout, positioned toward the trailing edge (near the Digital Crown). It
/// fades in when `level` changes and fades out ~1.2s after the last change — never on appearance,
/// since `.onChange(of:)` does not fire for the initial value.
struct WatchVolumeHUDOverlay: View {
    let level: Float

    @State private var isVisible = false
    @State private var hideTask: Task<Void, Never>?

    private static let visibleDuration: UInt64 = 1_200_000_000

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                gauge
                    .padding(.trailing, 2)
            }
        }
        .padding(.bottom, 8)
        .allowsHitTesting(false)
        .onChange(of: level) { _, _ in showThenScheduleHide() }
        .onDisappear { hideTask?.cancel() }
    }

    private var gauge: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.18))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white)
                        .frame(height: proxy.size.height * CGFloat(level))
                }
            }
            .frame(width: 8, height: 46)

            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 9))
                .foregroundStyle(.white)
        }
        .padding(6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
        .opacity(isVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isVisible)
    }

    private func showThenScheduleHide() {
        hideTask?.cancel()
        isVisible = true
        hideTask = Task {
            try? await Task.sleep(nanoseconds: Self.visibleDuration)
            guard !Task.isCancelled else { return }
            isVisible = false
        }
    }
}
