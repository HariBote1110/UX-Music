import Foundation

/// Persisted settings for both iPhone and Watch apps
struct WearSettings: Codable {
    /// e.g. "192.168.1.5"
    var serverHost: String
    /// default 8765
    var serverPort: Int

    var baseURL: URL? {
        URL(string: "http://\(serverHost):\(serverPort)")
    }

    static let `default` = WearSettings(serverHost: "", serverPort: 8765)

    private static let key = "ux_music_wear_settings"

    static func load() -> WearSettings {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let settings = try? JSONDecoder().decode(WearSettings.self, from: data)
        else { return .default }
        return settings
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
