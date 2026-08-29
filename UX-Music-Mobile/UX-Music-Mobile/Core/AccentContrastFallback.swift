import SwiftUI
import UIKit

/// Fallback for artwork-derived accent colours that would not read clearly as an "active" state
/// against the dim `.white.opacity(0.55)` inactive tint on the Now Playing transport row
/// (shuffle/repeat toggles). Some album artwork yields a palette accent that is nearly white or
/// nearly grey — indistinguishable from "off" at a glance. Mirrors the Watch app's simpler fixed
/// approach (`WatchModeIconViews.swift`'s shuffle/repeat icons always tint `.blue` when active,
/// never deriving from artwork) by falling back to a fixed high-contrast colour in that case,
/// while still using the real accent whenever it is vivid/dark enough to read on its own.
enum AccentContrastFallback {
    /// Fixed high-contrast colour used in place of a too-washed-out accent.
    static let fixedFallback = Color.blue

    /// Pure predicate on HSB components (each `0...1`): true when a colour this bright and this
    /// desaturated would not stand out against `.white.opacity(0.55)` — i.e. it is close enough to
    /// white/light-grey that "accent-tinted" and "dimmed-white" look the same.
    static func isTooLowContrast(saturation: CGFloat, brightness: CGFloat) -> Bool {
        brightness > 0.88 && saturation < 0.35
    }

    /// Resolves `accent` to itself, unless it is too washed-out per `isTooLowContrast`, in which
    /// case `fixedFallback` is used instead.
    static func resolvedAccent(for accent: Color) -> Color {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(accent).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            // Non-RGB-representable colour (e.g. a pattern/gradient `Color`) — keep as-is rather
            // than guessing.
            return accent
        }
        return isTooLowContrast(saturation: saturation, brightness: brightness) ? fixedFallback : accent
    }
}
