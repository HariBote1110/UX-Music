import Foundation

struct RuntimeConfiguration {
    let useDummyPipeline: Bool
    let modelCacheDirectory: String?
    let allowModelDownloadFromEnvironment: Bool

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> RuntimeConfiguration {
        RuntimeConfiguration(
            useDummyPipeline: environmentFlag(named: "UX_MUSIC_LYRICS_SYNC_DUMMY", in: environment),
            modelCacheDirectory: sanitise(environment["UX_MUSIC_MODEL_CACHE"]),
            allowModelDownloadFromEnvironment: sanitise(environment["UX_MUSIC_HF_DOWNLOAD"]) == "allow"
        )
    }

    private static func environmentFlag(named name: String, in environment: [String: String]) -> Bool {
        let value = environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return value == "1" || value == "true" || value == "yes"
    }

    private static func sanitise(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return nil
    }
}
