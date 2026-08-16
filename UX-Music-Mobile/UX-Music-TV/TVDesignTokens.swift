import SwiftUI

/// Shared "cinematic" (案B) design tokens for the tvOS app — carried over from the desktop app's
/// charcoal + signature pink→blue gradient identity (see `progress/tvos-design.md`). Centralised
/// here so every screen (Now Playing, Browse, Pairing/Discovery) reads from one palette instead of
/// re-deriving colours ad hoc.
enum TVDesignTokens {
    /// Base charcoal background, darkest layer.
    static let charcoalBase = Color(red: 0x16 / 255, green: 0x16 / 255, blue: 0x18 / 255)
    /// Slightly lifted charcoal for cards/surfaces.
    static let charcoalSurface = Color(red: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255)
    /// Further-lifted charcoal for hovered/focused surfaces.
    static let charcoalRaised = Color(red: 0x2c / 255, green: 0x2c / 255, blue: 0x2e / 255)

    static let textSecondary = Color(red: 0xa1 / 255, green: 0xa1 / 255, blue: 0xaa / 255)
    static let textTertiary = Color(red: 0x71 / 255, green: 0x71 / 255, blue: 0x7a / 255)

    /// UX Music signature gradient: pink → blue, used for progress fills, EQ colours on desktop,
    /// and (here) focus accents / lyric accent bars.
    static let signaturePink = Color(red: 0xff / 255, green: 0x5d / 255, blue: 0x77 / 255)
    static let signatureBlue = Color(red: 0x3b / 255, green: 0x82 / 255, blue: 0xf6 / 255)

    static var signatureGradient: LinearGradient {
        LinearGradient(colors: [signaturePink, signatureBlue], startPoint: .leading, endPoint: .trailing)
    }

    static var signatureAngularGradient: LinearGradient {
        LinearGradient(colors: [signaturePink, signatureBlue], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Full-bleed charcoal background with soft radial "light pools" — pink glow upper-left, blue glow
/// lower-right — the shared backdrop language across Now Playing, Browse, and Pairing. Static
/// radial gradients only (no live blur) so it stays smooth on tvOS; `breathing` slowly drifts
/// opacity/position for the ambient continuation instead of animating blur radius.
struct TVCinematicBackground: View {
    /// When `true`, pools breathe slowly and dim slightly — used by the ambient state and by
    /// dimmer secondary screens (Browse, Pairing).
    var breathing: Bool = false
    /// Overall pool intensity; Browse/Pairing use a dimmer value than Now Playing per the design.
    var intensity: Double = 1.0

    @State private var drift = false

    var body: some View {
        ZStack {
            TVDesignTokens.charcoalBase

            RadialGradient(
                colors: [TVDesignTokens.signaturePink.opacity(0.35 * intensity), .clear],
                center: UnitPoint(x: 0.12, y: 0.08),
                startRadius: 0,
                endRadius: 700
            )

            RadialGradient(
                colors: [TVDesignTokens.signatureBlue.opacity(0.32 * intensity), .clear],
                center: UnitPoint(x: 0.92, y: 0.95),
                startRadius: 0,
                endRadius: 800
            )
        }
        .opacity(breathing && drift ? 0.7 : 1.0)
        .ignoresSafeArea()
        .onAppear {
            guard breathing else { return }
            withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }
}

/// Thin gradient-filled progress strip (pink→blue) used in place of the stock `ProgressView` on
/// Now Playing, matching the desktop app's progress bar treatment.
struct TVGradientProgressBar: View {
    /// 0...1
    let fraction: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(TVDesignTokens.signatureGradient)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
    }
}

/// Focus treatment for browse shelf cards: a gradient (pink→blue) edge glow replacing the stock
/// white focus halo, applied via `@Environment(\.isFocused)` — mirrors `TVTransportButtonStyle`'s
/// approach in `TVNowPlayingView.swift`. `.buttonStyle(.plain)` is required alongside this so the
/// system `.card` style's own white halo doesn't also draw.
struct TVCinematicCardStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(TVDesignTokens.charcoalSurface)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        isFocused ? AnyShapeStyle(TVDesignTokens.signatureAngularGradient) : AnyShapeStyle(Color.clear),
                        lineWidth: 3
                    )
            )
            .shadow(
                color: TVDesignTokens.signaturePink.opacity(isFocused ? 0.35 : 0),
                radius: isFocused ? 24 : 0
            )
            .scaleEffect((isFocused ? 1.06 : 1.0) * (configuration.isPressed ? 0.97 : 1.0))
            .animation(.easeInOut(duration: 0.15), value: isFocused)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
