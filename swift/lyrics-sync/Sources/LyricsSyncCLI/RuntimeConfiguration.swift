import Foundation
import CoreML

enum RuntimeFlagPolicy {
    case automatic
    case enabled
    case disabled
}

enum ChunkingPolicy {
    case automatic
    case disabled
    case vad
}

enum ForcedAlignerPolicy {
    case automatic
    case enabled
    case disabled
}

struct RuntimeConfiguration {
    let useDummyPipeline: Bool
    let modelCacheDirectory: String?
    let allowModelDownloadFromEnvironment: Bool
    let preferredModelName: String?
    let concurrentWorkerCount: Int?
    let temperatureFallbackCount: Int?
    let usePrefillCache: Bool
    let wordTimestampsEnabled: Bool
    let modelRepository: String?
    let modelEndpoint: String?
    let backgroundDownloadEnabled: Bool
    let prewarmPolicy: RuntimeFlagPolicy
    let loadPolicy: RuntimeFlagPolicy
    let chunkingPolicy: ChunkingPolicy
    let audioEncoderComputeUnits: MLComputeUnits
    let textDecoderComputeUnits: MLComputeUnits
    let prefillComputeUnits: MLComputeUnits
    let melComputeUnits: MLComputeUnits
    let forcedAlignerPolicy: ForcedAlignerPolicy
    let forcedAlignerBinary: String?
    let forcedAlignerModel: String?

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> RuntimeConfiguration {
        RuntimeConfiguration(
            useDummyPipeline: environmentFlag(named: "UX_MUSIC_LYRICS_SYNC_DUMMY", in: environment),
            modelCacheDirectory: sanitise(environment["UX_MUSIC_MODEL_CACHE"]),
            allowModelDownloadFromEnvironment: sanitise(environment["UX_MUSIC_HF_DOWNLOAD"]) == "allow",
            preferredModelName: sanitise(environment["UX_MUSIC_LYRICS_SYNC_SWIFT_MODEL"]),
            concurrentWorkerCount: sanitiseInt(environment["UX_MUSIC_LYRICS_SYNC_SWIFT_WORKERS"]),
            temperatureFallbackCount: sanitiseInt(environment["UX_MUSIC_LYRICS_SYNC_SWIFT_FALLBACKS"]),
            usePrefillCache: !environmentFlag(named: "UX_MUSIC_LYRICS_SYNC_SWIFT_DISABLE_PREFILL_CACHE", in: environment),
            wordTimestampsEnabled: environmentFlag(named: "UX_MUSIC_LYRICS_SYNC_SWIFT_WORD_TIMESTAMPS", in: environment),
            modelRepository: sanitise(environment["UX_MUSIC_LYRICS_SYNC_SWIFT_MODEL_REPO"]),
            modelEndpoint: sanitise(environment["UX_MUSIC_LYRICS_SYNC_SWIFT_MODEL_ENDPOINT"]),
            backgroundDownloadEnabled: environmentFlag(named: "UX_MUSIC_LYRICS_SYNC_SWIFT_BACKGROUND_DOWNLOAD", in: environment),
            prewarmPolicy: runtimeFlagPolicy(from: environment["UX_MUSIC_LYRICS_SYNC_SWIFT_PREWARM"]),
            loadPolicy: runtimeFlagPolicy(from: environment["UX_MUSIC_LYRICS_SYNC_SWIFT_LOAD"]),
            chunkingPolicy: chunkingPolicy(from: environment["UX_MUSIC_LYRICS_SYNC_SWIFT_CHUNKING"]),
            audioEncoderComputeUnits: computeUnits(from: environment["UX_MUSIC_LYRICS_SYNC_SWIFT_AUDIO_COMPUTE"]) ?? defaultAudioEncoderComputeUnits(),
            textDecoderComputeUnits: computeUnits(from: environment["UX_MUSIC_LYRICS_SYNC_SWIFT_TEXT_COMPUTE"]) ?? .cpuAndNeuralEngine,
            prefillComputeUnits: computeUnits(from: environment["UX_MUSIC_LYRICS_SYNC_SWIFT_PREFILL_COMPUTE"]) ?? .cpuOnly,
            melComputeUnits: computeUnits(from: environment["UX_MUSIC_LYRICS_SYNC_SWIFT_MEL_COMPUTE"]) ?? .cpuAndGPU,
            forcedAlignerPolicy: forcedAlignerPolicy(from: environment["UX_MUSIC_LYRICS_SYNC_ALIGNER"]),
            forcedAlignerBinary: sanitise(environment["UX_MUSIC_LYRICS_SYNC_ALIGNER_BIN"]),
            forcedAlignerModel: sanitise(environment["UX_MUSIC_LYRICS_SYNC_ALIGNER_MODEL"])
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

    private static func sanitiseInt(_ value: String?) -> Int? {
        guard let clean = sanitise(value), let parsed = Int(clean) else {
            return nil
        }
        return parsed
    }

    private static func runtimeFlagPolicy(from raw: String?) -> RuntimeFlagPolicy {
        guard let clean = sanitise(raw)?.lowercased() else {
            return .automatic
        }
        switch clean {
        case "1", "true", "yes", "always", "on":
            return .enabled
        case "0", "false", "no", "never", "off":
            return .disabled
        default:
            return .automatic
        }
    }

    private static func chunkingPolicy(from raw: String?) -> ChunkingPolicy {
        guard let clean = sanitise(raw)?.lowercased() else {
            return .automatic
        }
        switch clean {
        case "vad":
            return .vad
        case "none", "off", "disabled":
            return .disabled
        default:
            return .automatic
        }
    }

    private static func forcedAlignerPolicy(from raw: String?) -> ForcedAlignerPolicy {
        guard let clean = sanitise(raw)?.lowercased() else {
            return .automatic
        }
        switch clean {
        case "1", "true", "yes", "on", "qwen3", "forced", "aligner":
            return .enabled
        case "0", "false", "no", "off", "disabled", "whisperkit":
            return .disabled
        default:
            return .automatic
        }
    }

    private static func computeUnits(from raw: String?) -> MLComputeUnits? {
        guard let clean = sanitise(raw)?.lowercased() else {
            return nil
        }
        switch clean {
        case "all":
            return .all
        case "cpuonly", "cpu":
            return .cpuOnly
        case "cpuandgpu", "gpu":
            return .cpuAndGPU
        case "cpuandneuralengine", "ane", "neural":
            return .cpuAndNeuralEngine
        default:
            return nil
        }
    }

    private static func defaultAudioEncoderComputeUnits() -> MLComputeUnits {
        if #available(macOS 14.0, *) {
            return .cpuAndNeuralEngine
        }
        return .cpuAndGPU
    }
}
