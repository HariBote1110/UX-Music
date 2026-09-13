import Foundation

/// Bass-onset timestamps and normalised peak strengths shared by iOS and watchOS.
struct WatchHapticMap: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let minimumOnsetGap: Double = 0.125
    var version: Int
    var songId: String
    var onsetTimes: [Double]
    var strengths: [Float]
}

extension WatchTransferMeta {
    static let kindHaptics = "haptics"
    static let applicationContextLibrarySongIDsKey = "watchLibrarySongIds"

    static func hapticsWcMetadata(songId: String) -> [String: Any] {
        [metadataIDKey: songId, metadataKindKey: kindHaptics]
    }

    static func isHapticsWcMetadata(_ metadata: [String: Any]?) -> Bool {
        metadata?[metadataKindKey] as? String == kindHaptics
    }
}
