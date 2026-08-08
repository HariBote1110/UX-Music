import SwiftUI

/// Fixed-position header shared by the Local/Remote library screens.
///
/// Uses the stock `Picker(.segmented)` style on a fully transparent background so the control
/// blends into the surrounding black content rather than sitting on a distinct grey bar. A
/// previous custom capsule implementation (with its own glass effect and matched-geometry
/// selection highlight) was replaced because it read as dim/low-contrast and its slide animation
/// felt unnatural; on iOS 26 the system already renders `.segmented` with native Liquid Glass and
/// a native slide transition, so no custom implementation is needed.
///
/// Two things it deliberately does *not* do:
///
/// - No "too many segments" fallback. A horizontally scrolling row of custom capsules used to kick
///   in above three segments; it was the last control here that did not look like a system part and
///   was fiddly to hit. Callers keep their segment count low enough for the native picker instead.
/// - No trailing accessory slot. `.segmented` apportions its segments equally, so even 32pt stolen
///   from the row truncates a six-character Japanese label ("アーティ…"). The picker gets the full
///   width and per-tab accessories live in the row below (see `LibrarySearchRow`).
struct LibrarySegmentedHeader: View {
    let segments: [String]
    @Binding var selectedIndex: Int

    var body: some View {
        Picker("View", selection: $selectedIndex) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, title in
                Text(title).tag(index)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }
}

/// Search field plus the current tab's accessory buttons — the row that sits directly under
/// `LibrarySegmentedHeader` on every library page.
///
/// The accessory slot keeps a fixed minimum width whether or not a tab fills it, so paging between
/// tabs never resizes the search field.
///
/// NOTE: any `.ultraThinMaterial` circle backdrop must live inside each caller's `accessory`
/// content (not here). A background applied at this level stays visible even when the wrapped
/// content sets its own `.opacity(0)`/`.hidden()`, because it is a sibling layer rather than part
/// of the same hidden subview — this previously produced a faint ghost circle on tabs where the
/// accessory should be fully hidden.
struct LibrarySearchRow<Accessory: View>: View {
    @Binding var query: String
    var prompt: String = "曲・アーティスト・アルバムを検索"
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(prompt, text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(Color(red: 0.17, green: 0.17, blue: 0.18))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            accessory()
                .frame(minWidth: 32, minHeight: 32, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

/// Lets a screen's scrolling content run underneath the floating tab bar (and the mini player
/// accessory) instead of stopping dead at its top edge, which reads as the list being sliced off by
/// a black band.
///
/// Extends its content past the bottom safe area and hands the inset it just gave up to the
/// closure, so the caller can re-apply it as scroll *content* margin — the last row then still
/// scrolls clear of the bar. Measuring it here rather than hard-coding a height keeps it correct
/// across devices and whether or not the mini player is showing.
struct LibraryBottomBleed<Content: View>: View {
    @ViewBuilder var content: (CGFloat) -> Content

    var body: some View {
        GeometryReader { proxy in
            content(proxy.safeAreaInsets.bottom)
        }
        .ignoresSafeArea(.container, edges: .bottom)
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
