import SwiftUI

/// Fixed-position header row shared by the Local/Remote library screens.
///
/// The segmented control always renders at the same horizontal position regardless of which
/// tab is selected, and the trailing accessory (if any) always reserves the same amount of
/// space so switching tabs never shifts the picker.
///
/// Uses a custom capsule-shaped segmented control (matching the app's original design) instead
/// of the stock `Picker(.segmented)` style, and renders on a fully transparent background so the
/// header blends into the surrounding black content rather than sitting on a distinct grey bar.
struct LibrarySegmentedHeader<Trailing: View>: View {
    let segments: [String]
    @Binding var selectedIndex: Int
    @ViewBuilder var trailing: () -> Trailing

    @Namespace private var segmentNamespace

    var body: some View {
        HStack(spacing: 12) {
            capsuleSegmentedControl
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

    private var capsuleSegmentedControl: some View {
        HStack(spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, title in
                let isSelected = selectedIndex == index
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        selectedIndex = index
                    }
                } label: {
                    Text(title)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color(white: 0.22))
                                    .matchedGeometryEffect(id: "librarySegmentSelection", in: segmentNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Color(white: 0.12)))
    }
}

extension LibrarySegmentedHeader where Trailing == Color {
    init(segments: [String], selectedIndex: Binding<Int>) {
        self.segments = segments
        self._selectedIndex = selectedIndex
        self.trailing = { Color.clear }
    }
}
