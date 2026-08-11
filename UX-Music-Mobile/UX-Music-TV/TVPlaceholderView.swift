import SwiftUI

/// Placeholder Now Playing-less shell shown until Phase 1-3 (10-foot browsing UI)
/// and Phase 1-4 (streaming playback) land.
struct TVPlaceholderView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "tv")
                .font(.system(size: 96))
            Text("UX Music for Apple TV")
                .font(.title)
            Text("Coming soon")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    TVPlaceholderView()
}
