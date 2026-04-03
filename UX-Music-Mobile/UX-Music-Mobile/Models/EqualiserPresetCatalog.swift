import Foundation

/// Built-in presets. To add your tuned curves, paste JSON objects into this array (or send the same JSON to maintainers).
enum EqualiserPresetCatalog {
    /// JSON array of `EqualiserPreset`. Frequencies are implicit — only `bandGainsDb` order matters (31 Hz … 16 kHz).
    static let embeddedJSON: String = """
    [
      {
        "id": "flat",
        "displayName": "Flat",
        "preampDb": 0,
        "bandGainsDb": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
      },
      {
        "id": "bass_boost",
        "displayName": "Bass boost",
        "preampDb": -1.5,
        "bandGainsDb": [5, 4, 3, 1.5, 0, 0, 0, 0, 0, 0]
      },
      {
        "id": "treble_soft",
        "displayName": "Softer treble",
        "preampDb": 0,
        "bandGainsDb": [0, 0, 0, 0, 0, 0, -1, -2, -3, -3]
      },
      {
        "id": "vocal_lift",
        "displayName": "Vocal lift",
        "preampDb": -0.5,
        "bandGainsDb": [-1, -0.5, 0, 1.5, 3, 3.5, 2, 0.5, 0, -0.5]
      }
    ]
    """

    static let builtInPresets: [EqualiserPreset] = {
        (try? EqualiserPresetCodec.decodeList(jsonString: embeddedJSON)) ?? []
    }()
}
