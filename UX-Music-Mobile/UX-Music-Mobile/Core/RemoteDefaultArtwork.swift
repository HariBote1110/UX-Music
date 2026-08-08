import UIKit

private final class RemoteDefaultArtworkBundleAnchor {}

/// Bundled jacket shown when the Remote API has no extracted artwork (matches desktop `default_artwork.png`).
enum RemoteDefaultArtwork {
    private static let assetName = "RemoteDefaultArtwork"

    /// Uses the application bundle so unit tests resolve the asset when `Bundle.main` is the test host.
    static func uiImage() -> UIImage? {
        let bundle = Bundle(for: RemoteDefaultArtworkBundleAnchor.self)
        return UIImage(named: assetName, in: bundle, compatibleWith: nil)
    }
}
