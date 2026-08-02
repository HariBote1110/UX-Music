import SwiftUI

/// Fixed-position header row shared by the Local/Remote library screens.
///
/// The segmented control always renders at the same horizontal position regardless of which
/// tab is selected, and the trailing accessory (if any) always reserves the same amount of
/// space so switching tabs never shifts the picker.
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

            trailing()
                .frame(minWidth: 32, minHeight: 32, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
    }
}

extension LibrarySegmentedHeader where Trailing == Color {
    init(segments: [String], selectedIndex: Binding<Int>) {
        self.segments = segments
        self._selectedIndex = selectedIndex
        self.trailing = { Color.clear }
    }
}
