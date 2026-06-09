import AVFoundation
import CoreML
import Foundation
import WhisperKit

enum PerformanceProfile {
    case fast
    case balanced
    case quality

    init(_ raw: String?) {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "fast":
            self = .fast
        case "accurate", "quality":
            self = .quality
        default:
            self = .balanced
        }
    }
}

struct WhisperKitBootstrapPlan {
    let selectedModel: String
    let allowModelDownload: Bool
    let languageHint: String?
    let profile: PerformanceProfile
    let modelCacheDirectory: String?
    let modelRepository: String?
    let modelEndpoint: String?
    let backgroundDownloadEnabled: Bool
    let concurrentWorkerCount: Int
    let usePrefillCache: Bool
    let temperatureFallbackCount: Int
    let wordTimestampsEnabled: Bool
    let chunkingStrategy: ChunkingStrategy?
    let computeOptions: ModelComputeOptions
    let prewarm: Bool
    let loadAtStartup: Bool
    let prewarmSentinelPath: String?

    init(request: Request, configuration: RuntimeConfiguration, audioDurationSeconds: Double?) {
        let requestedModel = Self.sanitise(request.whisperModel)
        let languageHint = Self.resolveLanguageHint(request.language)
        let profile = PerformanceProfile(request.profile)
        let allowModelDownload = (request.allowModelDownload ?? false) || configuration.allowModelDownloadFromEnvironment
        let selectedModel = Self.resolveModelName(
            requested: requestedModel,
            preferred: configuration.preferredModelName,
            profile: profile,
            languageHint: languageHint
        )
        let prewarmSentinelPath = Self.makePrewarmSentinelPath(
            cacheDirectory: configuration.modelCacheDirectory,
            modelName: selectedModel,
            computeOptions: configuration
        )

        self.selectedModel = selectedModel
        self.allowModelDownload = allowModelDownload
        self.languageHint = languageHint
        self.profile = profile
        self.modelCacheDirectory = configuration.modelCacheDirectory
        self.modelRepository = configuration.modelRepository
        self.modelEndpoint = configuration.modelEndpoint
        self.backgroundDownloadEnabled = configuration.backgroundDownloadEnabled
        self.concurrentWorkerCount = Self.resolveWorkerCount(
            override: configuration.concurrentWorkerCount,
            profile: profile,
            modelName: selectedModel,
            audioDurationSeconds: audioDurationSeconds,
            lyricLineCount: request.lines.count
        )
        self.usePrefillCache = configuration.usePrefillCache
        self.temperatureFallbackCount = Self.resolveFallbackCount(
            override: configuration.temperatureFallbackCount,
            profile: profile,
            languageHint: languageHint
        )
        self.wordTimestampsEnabled = configuration.wordTimestampsEnabled
        self.chunkingStrategy = Self.resolveChunkingStrategy(
            policy: configuration.chunkingPolicy,
            audioDurationSeconds: audioDurationSeconds
        )
        self.computeOptions = ModelComputeOptions(
            melCompute: configuration.melComputeUnits,
            audioEncoderCompute: configuration.audioEncoderComputeUnits,
            textDecoderCompute: configuration.textDecoderComputeUnits,
            prefillCompute: configuration.prefillComputeUnits
        )
        self.prewarmSentinelPath = prewarmSentinelPath
        self.prewarm = Self.resolvePrewarm(
            policy: configuration.prewarmPolicy,
            profile: profile,
            modelName: selectedModel,
            prewarmSentinelPath: prewarmSentinelPath
        )
        self.loadAtStartup = Self.resolveLoadAtStartup(
            policy: configuration.loadPolicy,
            prewarm: self.prewarm
        )
    }

    private static func sanitise(_ raw: String?) -> String? {
        let clean = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let clean, !clean.isEmpty else {
            return nil
        }
        return clean
    }

    private static func resolveLanguageHint(_ raw: String?) -> String? {
        let clean = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let clean, !clean.isEmpty else {
            return nil
        }
        switch clean {
        case "auto":
            return nil
        case "auto-ja":
            return "ja"
        case "auto-en":
            return "en"
        default:
            return clean
        }
    }

    private static func resolveModelName(
        requested raw: String?,
        preferred: String?,
        profile: PerformanceProfile,
        languageHint: String?
    ) -> String {
        if let raw {
            return normaliseModelName(raw)
        }
        if let preferred, !preferred.isEmpty {
            return normaliseModelName(preferred)
        }

        let recommended = normaliseModelName(WhisperKit.recommendedModels().default)

        switch profile {
        case .fast:
            if languageHint == "en" {
                return "base.en"
            }
            if recommended.contains("large") || recommended.contains("medium") {
                return "small"
            }
            return recommended
        case .quality:
            if recommended.contains("tiny") || recommended.contains("base") {
                return "medium"
            }
            return recommended
        case .balanced:
            return recommended
        }
    }

    private static func normaliseModelName(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else {
            return "medium"
        }

        let dePrefixed: String
        if lowered.hasPrefix("openai_whisper-") {
            dePrefixed = String(lowered.dropFirst("openai_whisper-".count))
        } else {
            dePrefixed = lowered
        }

        switch dePrefixed {
        case "large-v3-turbo":
            return "large-v3"
        default:
            return dePrefixed
        }
    }

    private static func resolveWorkerCount(
        override: Int?,
        profile: PerformanceProfile,
        modelName: String,
        audioDurationSeconds: Double?,
        lyricLineCount: Int
    ) -> Int {
        if let override, override > 0 {
            return override
        }

        let cpuCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let lowMemory = ProcessInfo.processInfo.physicalMemory <= 16 * 1024 * 1024 * 1024
        var workers = min(max(2, cpuCount / 2), 8)

        if modelName.contains("large") {
            workers = min(workers, 3)
        } else if modelName.contains("medium") {
            workers = min(workers, 4)
        }

        if let audioDurationSeconds, audioDurationSeconds < 90 {
            workers = min(workers, 2)
        }
        if lyricLineCount < 24 {
            workers = min(workers, 2)
        }
        if lowMemory {
            workers = min(workers, 4)
        }

        switch profile {
        case .fast:
            workers = min(workers, 3)
        case .balanced:
            workers = min(workers, 4)
        case .quality:
            workers = min(workers, 6)
        }

        return max(1, workers)
    }

    private static func resolveFallbackCount(
        override: Int?,
        profile: PerformanceProfile,
        languageHint: String?
    ) -> Int {
        if let override, override >= 0 {
            return override
        }

        switch profile {
        case .fast:
            return 0
        case .quality:
            return languageHint == nil ? 2 : 1
        case .balanced:
            return languageHint == nil ? 1 : 0
        }
    }

    private static func resolveChunkingStrategy(
        policy: ChunkingPolicy,
        audioDurationSeconds: Double?
    ) -> ChunkingStrategy? {
        switch policy {
        case .vad:
            return .vad
        case .disabled:
            return ChunkingStrategy.none
        case .automatic:
            guard let audioDurationSeconds, audioDurationSeconds >= 300 else {
                return nil
            }
            return .vad
        }
    }

    private static func resolvePrewarm(
        policy: RuntimeFlagPolicy,
        profile: PerformanceProfile,
        modelName: String,
        prewarmSentinelPath: String?
    ) -> Bool {
        switch policy {
        case .enabled:
            return true
        case .disabled:
            return false
        case .automatic:
            guard let prewarmSentinelPath, !FileManager.default.fileExists(atPath: prewarmSentinelPath) else {
                return false
            }
            let lowMemory = ProcessInfo.processInfo.physicalMemory <= 16 * 1024 * 1024 * 1024
            if profile == .fast {
                return false
            }
            return lowMemory || modelName.contains("large")
        }
    }

    private static func resolveLoadAtStartup(
        policy: RuntimeFlagPolicy,
        prewarm: Bool
    ) -> Bool {
        switch policy {
        case .enabled:
            return true
        case .disabled:
            return false
        case .automatic:
            return true
        }
    }

    private static func makePrewarmSentinelPath(
        cacheDirectory: String?,
        modelName: String,
        computeOptions: RuntimeConfiguration
    ) -> String? {
        guard let cacheDirectory, !cacheDirectory.isEmpty else {
            return nil
        }
        let fingerprint = [
            modelName,
            String(describing: computeOptions.melComputeUnits),
            String(describing: computeOptions.audioEncoderComputeUnits),
            String(describing: computeOptions.textDecoderComputeUnits),
            String(describing: computeOptions.prefillComputeUnits),
        ]
            .joined(separator: "__")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        return URL(filePath: cacheDirectory)
            .appending(path: ".uxmusic-whisperkit-prewarm")
            .appending(path: "\(fingerprint).ready")
            .path()
    }
}

struct WhisperKitPipeline: LyricsSyncPipeline {
    let detectedBy = "swift-whisperkit"

    private let configuration: RuntimeConfiguration
    private let progress: ProgressEmitter

    init(configuration: RuntimeConfiguration, progress: ProgressEmitter) {
        self.configuration = configuration
        self.progress = progress
    }

    func run(request: Request) async throws -> Result {
        guard FileManager.default.fileExists(atPath: request.songPath) else {
            throw CLIError.invalidSongPath(request.songPath)
        }
        if request.lines.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw CLIError.noLyricsLines
        }

        let audioDurationSeconds = detectAudioDuration(at: request.songPath)
        let plan = WhisperKitBootstrapPlan(
            request: request,
            configuration: configuration,
            audioDurationSeconds: audioDurationSeconds
        )

        progress.emit(stage: "bootstrap", percent: 5.0)
        progress.emit(stage: "prepare-whisperkit", percent: 15.0)
        let whisperKit = try await buildWhisperKit(plan: plan)
        try markPrewarmIfNeeded(plan: plan)

        progress.emit(stage: "asr_run", percent: 45.0)
        let options = buildDecodingOptions(plan: plan)
        let transcription = try await whisperKit.transcribe(
            audioPath: request.songPath,
            decodeOptions: options
        )
        let segments = extractSegments(from: transcription)
        guard !segments.isEmpty else {
            throw CLIError.transcriptionFailed
        }

        progress.emit(stage: "align_start", percent: 80.0)
        let alignedLines = LyricsAligner.align(lines: request.lines, segments: segments)
        let matchedCount = alignedLines.reduce(into: 0) { count, line in
            if line.source == "match" {
                count += 1
            }
        }

        progress.emit(stage: "done", percent: 100.0)
        return Result(
            success: true,
            lines: alignedLines,
            matchedCount: matchedCount,
            detectedBy: detectedBy,
            detectedSegments: segments,
            error: nil
        )
    }

    private func buildWhisperKit(plan: WhisperKitBootstrapPlan) async throws -> WhisperKit {
        let tokenizerDirectory = plan.modelCacheDirectory.map { URL(filePath: $0) }
        let config = WhisperKitConfig(
            model: plan.selectedModel,
            modelRepo: plan.modelRepository,
            modelEndpoint: plan.modelEndpoint,
            modelFolder: plan.modelCacheDirectory,
            tokenizerFolder: tokenizerDirectory,
            computeOptions: plan.computeOptions,
            verbose: false,
            prewarm: plan.prewarm,
            load: plan.loadAtStartup,
            download: plan.allowModelDownload,
            useBackgroundDownloadSession: plan.backgroundDownloadEnabled
        )
        return try await WhisperKit(config)
    }

    private func buildDecodingOptions(plan: WhisperKitBootstrapPlan) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: plan.languageHint,
            temperatureFallbackCount: plan.temperatureFallbackCount,
            usePrefillPrompt: true,
            usePrefillCache: plan.usePrefillCache,
            detectLanguage: plan.languageHint == nil,
            withoutTimestamps: false,
            wordTimestamps: plan.wordTimestampsEnabled,
            concurrentWorkerCount: plan.concurrentWorkerCount,
            chunkingStrategy: plan.chunkingStrategy
        )
    }

    private func extractSegments(from transcription: [TranscriptionResult]) -> [DetectedSegment] {
        transcription
            .flatMap(\.segments)
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { segment in
                DetectedSegment(
                    start: Double(segment.start),
                    end: Double(segment.end),
                    text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
    }

    private func detectAudioDuration(at path: String) -> Double? {
        guard let audioFile = try? AVAudioFile(forReading: URL(filePath: path)) else {
            return nil
        }
        let sampleRate = audioFile.processingFormat.sampleRate
        guard sampleRate > 0 else {
            return nil
        }
        return Double(audioFile.length) / sampleRate
    }

    private func markPrewarmIfNeeded(plan: WhisperKitBootstrapPlan) throws {
        guard plan.prewarm, let prewarmSentinelPath = plan.prewarmSentinelPath else {
            return
        }
        let sentinelURL = URL(filePath: prewarmSentinelPath)
        let directory = sentinelURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: sentinelURL.path()) {
            FileManager.default.createFile(atPath: sentinelURL.path(), contents: Data())
        }
    }
}
