import UIKit

/// Backing store for `AppDelegate.application(_:supportedInterfaceOrientationsFor:)`. A plain
/// static var rather than a SwiftUI `@State` because UIKit calls the delegate method directly, with
/// no SwiftUI environment available. `SidecarScreen` updates this (via `SidecarOrientationPolicy`)
/// on `onAppear`/`onDisappear` and calls `UIWindowScene.requestGeometryUpdate` +
/// `setNeedsUpdateOfSupportedInterfaceOrientations` so UIKit re-reads it immediately.
enum SidecarOrientationLock {
    /// The mask to report while the sidecar is NOT presented. MUST match Info.plist's
    /// `UISupportedInterfaceOrientations` for the current idiom exactly — iPhone's Info.plist entry
    /// excludes portrait-upside-down while iPad's includes it. Reporting a broader mask (e.g. `.all`
    /// on iPhone) makes the delegate disagree with Info.plist on every geometry query, which drives
    /// BackBoardServices into a continuous frame-invalidation loop
    /// (BLSInvalidateFrameSpecifiersAction) from launch onward — runaway CPU/RSS growth even though
    /// the sidecar is never shown. This was the root cause of the memory/CPU storm introduced
    /// alongside the sidecar orientation lock; see progress/sidecar-poll-tick-cpu-leak.md.
    static var defaultMask: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    static var current: UIInterfaceOrientationMask = defaultMask
}

/// Hosts `application(_:supportedInterfaceOrientationsFor:)` so the sidecar fullscreen display
/// (landscape-first: large artwork beside synced lyrics) can force landscape while presented and
/// restore the app's normal default mask on dismiss (see `SidecarOrientationLock`,
/// `SidecarOrientationPolicy`).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        SidecarOrientationLock.current
    }
}
