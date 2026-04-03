import Foundation

/// Matches `pkg/audio/player.go` (`equalizerFrequencies` / `equalizerBandCount`).
enum EqualiserConstants {
    static let bandCount = 10
    /// Hz — same order as desktop UX-Music (31 … 16 kHz).
    static let centreFrequenciesHz: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16_000]
}

/// One graphic-EQ preset (serialisable for sharing with maintainers / AI).
struct EqualiserPreset: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var displayName: String
    /// Overall gain in dB (`AVAudioUnitEQ.globalGain`).
    var preampDb: Float
    /// Per-band gain in dB; index aligns with `EqualiserConstants.centreFrequenciesHz`.
    var bandGainsDb: [Float]

    enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case preampDb
        case bandGainsDb
    }

    init(id: String, displayName: String, preampDb: Float, bandGainsDb: [Float]) {
        self.id = id
        self.displayName = displayName
        self.preampDb = preampDb
        self.bandGainsDb = Self.normalisedBands(bandGainsDb)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        preampDb = try c.decode(Float.self, forKey: .preampDb)
        let raw = try c.decode([Float].self, forKey: .bandGainsDb)
        bandGainsDb = Self.normalisedBands(raw)
    }

    private static func normalisedBands(_ raw: [Float]) -> [Float] {
        if raw.count == EqualiserConstants.bandCount { return raw }
        var out = Array(raw.prefix(EqualiserConstants.bandCount))
        while out.count < EqualiserConstants.bandCount { out.append(0) }
        return out
    }
}

/// Resolved shape applied to `AVAudioUnitEQ`.
struct EqualiserCurve: Equatable {
    var isEnabled: Bool
    var preampDb: Float
    var bandGainsDb: [Float]

    static let disabled = EqualiserCurve(isEnabled: false, preampDb: 0, bandGainsDb: Array(repeating: 0, count: EqualiserConstants.bandCount))
}

enum EqualiserPresetCodec {
    static func decodeList(jsonData: Data) throws -> [EqualiserPreset] {
        let decoder = JSONDecoder()
        let list = try decoder.decode([EqualiserPreset].self, from: jsonData)
        return list.filter { $0.bandGainsDb.count == EqualiserConstants.bandCount }
    }

    static func decodeList(jsonString: String) throws -> [EqualiserPreset] {
        guard let data = jsonString.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "UTF-8 data expected"))
        }
        return try decodeList(jsonData: data)
    }
}
