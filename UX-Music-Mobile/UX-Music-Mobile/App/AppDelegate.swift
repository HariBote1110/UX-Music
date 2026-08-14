import UIKit

/// Backing store for `AppDelegate.application(_:supportedInterfaceOrientationsFor:)`. A plain
/// static var rather than a SwiftUI `@State` because UIKit calls the delegate method directly, with
/// no SwiftUI environment available. `SidecarScreen` updates this (via `SidecarOrientationPolicy`)
/// on `onAppear`/`onDisappear` and calls `UIWindowScene.requestGeometryUpdate` +
/// `setNeedsUpdateOfSupportedInterfaceOrientations` so UIKit re-reads it immediately.
enum SidecarOrientationLock {
    static var current: UIInterfaceOrientationMask = .all
}

/// Hosts `application(_:supportedInterfaceOrientationsFor:)` so the sidecar fullscreen display
/// (landscape-first: large artwork beside synced lyrics) can force landscape while presented and
/// restore the app's normal `.all` mask on dismiss (see `SidecarOrientationLock`,
/// `SidecarOrientationPolicy`).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        SidecarOrientationLock.current
    }
}
