import SwiftUI

/// Minimal placeholder screen for the UX Music Watch companion app scaffold.
struct WatchRootView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 32))
                .foregroundStyle(.tint)
            Text("UX Music")
                .font(.headline)
        }
        .padding()
    }
}

#Preview {
    WatchRootView()
}
