import Foundation
import UIKit

/// Stable identity presented to the desktop when redeeming a pairing secret
/// (`POST /v1/pairing/redeem`), so the desktop can issue and later revoke a
/// device-specific auth token.
enum DeviceIdentity {
    private static let deviceIdDefaultsKey = "device_identity_id_v1"

    /// `UIDevice.identifierForVendor`, persisted as a fallback UUID if unavailable
    /// (e.g. under test, or before the device has been unlocked once after install).
    static var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdDefaultsKey), !existing.isEmpty {
            return existing
        }
        let generated = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(generated, forKey: deviceIdDefaultsKey)
        return generated
    }

    static var displayName: String {
        UIDevice.current.name
    }
}
