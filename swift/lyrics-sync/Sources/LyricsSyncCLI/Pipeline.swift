import Foundation

protocol LyricsSyncPipeline {
    var detectedBy: String { get }
    func run(request: Request) async throws -> Result
}

enum PipelineFactory {
    static func make(
        configuration: RuntimeConfiguration,
        progress: ProgressEmitter
    ) -> LyricsSyncPipeline {
        if configuration.useDummyPipeline {
            return DummyPipeline(progress: progress)
        }

        let whisperKit = WhisperKitPipeline(configuration: configuration, progress: progress)
        let forcedAligner = Qwen3ForcedAlignerPipeline(configuration: configuration, progress: progress)

        switch configuration.forcedAlignerPolicy {
        case .enabled:
            return forcedAligner
        case .automatic:
            if forcedAligner.isAvailable {
                return ForcedAlignerFirstPipeline(
                    forcedAligner: forcedAligner,
                    fallback: whisperKit,
                    progress: progress
                )
            }
            return whisperKit
        case .disabled:
            return whisperKit
        }
    }
}

struct ForcedAlignerFirstPipeline: LyricsSyncPipeline {
    let detectedBy = "swift-qwen3-forced-aligner"

    private let forcedAligner: Qwen3ForcedAlignerPipeline
    private let fallback: LyricsSyncPipeline
    private let progress: ProgressEmitter

    init(
        forcedAligner: Qwen3ForcedAlignerPipeline,
        fallback: LyricsSyncPipeline,
        progress: ProgressEmitter
    ) {
        self.forcedAligner = forcedAligner
        self.fallback = fallback
        self.progress = progress
    }

    func run(request: Request) async throws -> Result {
        do {
            return try await forcedAligner.run(request: request)
        } catch {
            progress.emit(stage: "forced_align_fallback", percent: 18.0)
            return try await fallback.run(request: request)
        }
    }
}
