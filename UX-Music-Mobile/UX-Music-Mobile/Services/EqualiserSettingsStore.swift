import Foundation
import Observation

@MainActor
@Observable
final class EqualiserSettingsStore {
    static let customPresetId = "custom"

    private(set) var presets: [EqualiserPreset] = EqualiserPresetCatalog.builtInPresets

    var isEnabled: Bool {
        didSet { if oldValue != isEnabled { mutated() } }
    }

    var selectedPresetId: String {
        didSet { if oldValue != selectedPresetId { mutated() } }
    }

    var customPreampDb: Float {
        didSet { if oldValue != customPreampDb { mutated() } }
    }

    var customBandGainsDb: [Float] {
        didSet { if oldValue != customBandGainsDb { mutated() } }
    }

    /// Called after any user-facing change so `MusicPlayerService` can re-read the curve.
    var onApplyRequested: (() -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: AppConstants.equaliserSettingsKey),
           let snap = try? JSONDecoder().decode(Persistence.self, from: data) {
            isEnabled = snap.isEnabled
            selectedPresetId = snap.selectedPresetId
            customPreampDb = snap.customPreampDb
            customBandGainsDb = Self.normaliseBands(snap.customBandGainsDb)
        } else {
            isEnabled = false
            selectedPresetId = "flat"
            customPreampDb = 0
            customBandGainsDb = Array(repeating: 0, count: EqualiserConstants.bandCount)
        }
    }

    func effectiveCurve() -> EqualiserCurve {
        guard isEnabled else { return .disabled }
        if selectedPresetId == Self.customPresetId {
            return EqualiserCurve(isEnabled: true, preampDb: customPreampDb, bandGainsDb: customBandGainsDb)
        }
        if let p = presets.first(where: { $0.id == selectedPresetId }) {
            return EqualiserCurve(isEnabled: true, preampDb: p.preampDb, bandGainsDb: p.bandGainsDb)
        }
        return .disabled
    }

    func displayName(forPresetId id: String) -> String {
        if id == Self.customPresetId { return "Custom" }
        return presets.first { $0.id == id }?.displayName ?? id
    }

    func setCustomBandGain(index: Int, value: Float) {
        guard index >= 0, index < EqualiserConstants.bandCount else { return }
        var next = customBandGainsDb
        guard index < next.count else { return }
        next[index] = value
        customBandGainsDb = next
    }

    func resetCustomToFlat() {
        customPreampDb = 0
        customBandGainsDb = Array(repeating: 0, count: EqualiserConstants.bandCount)
    }

    private func mutated() {
        save()
        onApplyRequested?()
    }

    private func save() {
        let snap = Persistence(
            isEnabled: isEnabled,
            selectedPresetId: selectedPresetId,
            customPreampDb: customPreampDb,
            customBandGainsDb: customBandGainsDb
        )
        if let data = try? JSONEncoder().encode(snap) {
            defaults.set(data, forKey: AppConstants.equaliserSettingsKey)
        }
    }

    private struct Persistence: Codable {
        var isEnabled: Bool
        var selectedPresetId: String
        var customPreampDb: Float
        var customBandGainsDb: [Float]
    }

    private static func normaliseBands(_ raw: [Float]) -> [Float] {
        if raw.count == EqualiserConstants.bandCount { return raw }
        var out = Array(raw.prefix(EqualiserConstants.bandCount))
        while out.count < EqualiserConstants.bandCount { out.append(0) }
        return out
    }
}
