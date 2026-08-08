import XCTest
@testable import UX_Music_Mobile

final class DeviceIdentityTests: XCTestCase {
    /// `identifierForVendor` can return the all-zero UUID on some simulators/devices
    /// (e.g. before the device has been unlocked once after install). Treating it as
    /// valid caused every affected device to register with the desktop under the same
    /// zero UUID, colliding in `deviceAuthTokens`. It must be rejected like `nil`.
    func testResolvedDeviceId_rejectsZeroUUIDVendorId_usesFallback() {
        let resolved = DeviceIdentity.resolvedDeviceId(
            existing: nil,
            vendorId: "00000000-0000-0000-0000-000000000000",
            generateFallback: { "fallback-uuid" }
        )
        XCTAssertEqual(resolved, "fallback-uuid")
    }

    func testResolvedDeviceId_rejectsNilVendorId_usesFallback() {
        let resolved = DeviceIdentity.resolvedDeviceId(
            existing: nil,
            vendorId: nil,
            generateFallback: { "fallback-uuid" }
        )
        XCTAssertEqual(resolved, "fallback-uuid")
    }

    func testResolvedDeviceId_usesVendorIdWhenValid() {
        let resolved = DeviceIdentity.resolvedDeviceId(
            existing: nil,
            vendorId: "1234ABCD-0000-0000-0000-000000000000",
            generateFallback: { "fallback-uuid" }
        )
        XCTAssertEqual(resolved, "1234ABCD-0000-0000-0000-000000000000")
    }

    /// A previously persisted zero UUID (from before this fix) must not keep being reused.
    func testResolvedDeviceId_rejectsPersistedZeroUUID_usesFallback() {
        let resolved = DeviceIdentity.resolvedDeviceId(
            existing: "00000000-0000-0000-0000-000000000000",
            vendorId: "00000000-0000-0000-0000-000000000000",
            generateFallback: { "fallback-uuid" }
        )
        XCTAssertEqual(resolved, "fallback-uuid")
    }

    func testResolvedDeviceId_reusesValidExistingValue() {
        let resolved = DeviceIdentity.resolvedDeviceId(
            existing: "existing-uuid",
            vendorId: "1234ABCD-0000-0000-0000-000000000000",
            generateFallback: { XCTFail("must not generate a new fallback"); return "unused" }
        )
        XCTAssertEqual(resolved, "existing-uuid")
    }
}
