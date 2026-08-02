import SwiftUI

/// Fixed-position header row shared by the Local/Remote library screens.
///
/// The segmented control always renders at the same horizontal position regardless of which
/// tab is selected, and the trailing accessory (if any) always reserves the same amount of
/// space so switching tabs never shifts the picker.
///
/// Uses the stock `Picker(.segmented)` style on a fully transparent background so the control
/// blends into the surrounding black content rather than sitting on a distinct grey bar. A
/// previous custom capsule implementation (with its own glass effect and matched-geometry
/// selection highlight) was replaced because it read as dim/low-contrast and its slide animation
/// felt unnatural; on iOS 26 the system already renders `.segmented` with native Liquid Glass and
/// a native slide transition, so no custom implementation is needed.
struct LibrarySegmentedHeader<Trailing: View>: View {
    let segments: [String]
    @Binding var selectedIndex: Int
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Picker("View", selection: $selectedIndex) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, title in
                    Text(title).tag(index)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)

            // NOTE: any `.ultraThinMaterial` circle backdrop must live inside each caller's
            // `trailing` content (not here). A background applied at this level stays visible
            // even when the wrapped content sets its own `.opacity(0)`/`.hidden()`, because it
            // is a sibling layer rather than part of the same hidden subview — this previously
            // produced a faint ghost circle on tabs where the accessory should be fully hidden.
            trailing()
                .frame(minWidth: 32, minHeight: 32, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }
}

extension LibrarySegmentedHeader where Trailing == Color {
    init(segments: [String], selectedIndex: Binding<Int>) {
        self.segments = segments
        self._selectedIndex = selectedIndex
        self.trailing = { Color.clear }
    }
}

/// Shared circular glass treatment for the header's trailing accessory buttons (ellipsis menu,
/// refresh, import) so they read as one system with the capsule segmented control and the
/// system tab bar's own glass material. Falls back to the previous `.ultraThinMaterial` circle
/// backdrop below iOS 26.
struct LibraryHeaderGlassButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .buttonStyle(.glass)
        } else {
            content
                .background(Circle().fill(.ultraThinMaterial))
        }
    }
}
