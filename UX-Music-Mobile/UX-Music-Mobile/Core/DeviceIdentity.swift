import Foundation
import UIKit

/// Stable identity presented to the desktop when redeeming a pairing secret
/// (`POST /v1/pairing/redeem`), so the desktop can issue and later revoke a
/// device-specific auth token.
enum DeviceIdentity {
    private static let deviceIdDefaultsKey = "device_identity_id_v1"

    /// `UIDevice.identifierForVendor` returns this all-zero UUID on some simulators/devices
    /// (e.g. before the device has been unlocked once after install). It must never be treated
    /// as a valid identity — otherwise every affected device registers under the same value in
    /// the desktop's `deviceAuthTokens`.
    static let zeroUUID = "00000000-0000-0000-0000-000000000000"

    /// Pure resolution logic, extracted for testability: decides the device id from a
    /// previously persisted value and the current vendor id, rejecting `nil`/empty/zero-UUID
    /// values and falling back to a freshly generated UUID when neither is usable.
    static func resolvedDeviceId(
        existing: String?,
        vendorId: String?,
        generateFallback: () -> String
    ) -> String {
        if let existing = existing, !existing.isEmpty, existing != zeroUUID {
            return existing
        }
        if let vendorId = vendorId, !vendorId.isEmpty, vendorId != zeroUUID {
            return vendorId
        }
        return generateFallback()
    }

    /// `UIDevice.identifierForVendor`, persisted as a fallback UUID if unavailable or invalid
    /// (e.g. under test, or before the device has been unlocked once after install).
    static var deviceId: String {
        let existing = UserDefaults.standard.string(forKey: deviceIdDefaultsKey)
        let resolved = resolvedDeviceId(
            existing: existing,
            vendorId: UIDevice.current.identifierForVendor?.uuidString,
            generateFallback: { UUID().uuidString }
        )
        if resolved != existing {
            UserDefaults.standard.set(resolved, forKey: deviceIdDefaultsKey)
        }
        return resolved
    }

    static var displayName: String {
        UIDevice.current.name
    }
}
