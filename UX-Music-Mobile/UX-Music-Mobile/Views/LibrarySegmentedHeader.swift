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

    @ViewBuilder
    private var capsuleSegmentedControl: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer {
                segmentButtons
                    .padding(4)
            }
            .glassEffect(.regular, in: Capsule())
        } else {
            segmentButtons
                .padding(4)
                .background(Capsule().fill(Color(white: 0.12)))
        }
    }

    private var segmentButtons: some View {
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
                                segmentSelectionHighlight
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var segmentSelectionHighlight: some View {
        if #available(iOS 26.0, *) {
            Capsule()
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: Capsule())
                .matchedGeometryEffect(id: "librarySegmentSelection", in: segmentNamespace)
        } else {
            Capsule()
                .fill(Color(white: 0.22))
                .matchedGeometryEffect(id: "librarySegmentSelection", in: segmentNamespace)
        }
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
