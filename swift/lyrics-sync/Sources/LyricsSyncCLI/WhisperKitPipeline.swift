import Foundation
import WhisperKit
import CoreML

struct WhisperKitBootstrapPlan {
    let selectedModel: String
    let allowModelDownload: Bool
    let languageHint: String?
    let profile: String?
    let modelCacheDirectory: String?
    let concurrentWorkerCount: Int
    let usePrefillCache: Bool
    let computeOptions: ModelComputeOptions

    init(request: Request, configuration: RuntimeConfiguration) {
        let requestedModel = request.whisperModel?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanProfile = request.profile?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.profile = cleanProfile
        self.selectedModel = Self.resolveModelName(
            requestedModel,
            preferred: configuration.preferredModelName,
            profile: cleanProfile
        )
        self.allowModelDownload = (request.allowModelDownload ?? false) || configuration.allowModelDownloadFromEnvironment
        self.languageHint = Self.resolveLanguageHint(request.language)
        self.modelCacheDirectory = configuration.modelCacheDirectory
        self.concurrentWorkerCount = configuration.concurrentWorkerCount ?? Self.resolveWorkerCount(profile: cleanProfile)
        self.usePrefillCache = configuration.usePrefillCache
        self.computeOptions = ModelComputeOptions(
            melCompute: configuration.melComputeUnits,
            audioEncoderCompute: configuration.audioEncoderComputeUnits,
            textDecoderCompute: configuration.textDecoderComputeUnits,
            prefillCompute: configuration.prefillComputeUnits
        )
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

    private static func resolveModelName(_ raw: String?, preferred: String?, profile: String?) -> String {
        guard let raw, !raw.isEmpty else {
            if let preferred, !preferred.isEmpty {
                return preferred
            }
            switch profile {
            case "accurate", "quality":
                return "medium"
            case "balanced":
                return "small"
            default:
                return "base"
            }
        }
        switch raw {
        case "large-v3-turbo":
            return "large-v3"
        default:
            return raw
        }
    }

    private static func resolveWorkerCount(profile: String?) -> Int {
        switch profile {
        case "accurate", "quality":
            return 2
        case "balanced":
            return 2
        default:
            return 1
        }
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
        let plan = WhisperKitBootstrapPlan(request: request, configuration: configuration)

        guard FileManager.default.fileExists(atPath: request.songPath) else {
            throw CLIError.invalidSongPath(request.songPath)
        }
        if request.lines.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw CLIError.noLyricsLines
        }

        progress.emit(stage: "bootstrap", percent: 5.0)
        progress.emit(stage: "prepare-whisperkit", percent: 15.0)
        let whisperKit = try await buildWhisperKit(plan: plan)

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
        let config = WhisperKitConfig(
            model: plan.selectedModel,
            modelFolder: plan.modelCacheDirectory,
            computeOptions: plan.computeOptions,
            verbose: false,
            prewarm: false,
            load: true,
            download: plan.allowModelDownload,
            useBackgroundDownloadSession: false
        )
        return try await WhisperKit(config)
    }

    private func buildDecodingOptions(plan: WhisperKitBootstrapPlan) -> DecodingOptions {
        DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: plan.languageHint,
            usePrefillPrompt: true,
            usePrefillCache: plan.usePrefillCache,
            detectLanguage: plan.languageHint == nil,
            withoutTimestamps: false,
            wordTimestamps: true,
            concurrentWorkerCount: plan.concurrentWorkerCount,
            chunkingStrategy: .vad
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
}
