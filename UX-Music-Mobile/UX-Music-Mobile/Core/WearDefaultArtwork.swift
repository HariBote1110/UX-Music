import UIKit

private final class WearDefaultArtworkBundleAnchor {}

/// Bundled jacket shown when Wear has no extracted artwork (matches desktop `default_artwork.png`).
enum WearDefaultArtwork {
    private static let assetName = "WearDefaultArtwork"

    /// Uses the application bundle so unit tests resolve the asset when `Bundle.main` is the test host.
    static func uiImage() -> UIImage? {
        let bundle = Bundle(for: WearDefaultArtworkBundleAnchor.self)
        return UIImage(named: assetName, in: bundle, compatibleWith: nil)
    }
}
