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

        return WhisperKitPipeline(configuration: configuration, progress: progress)
    }
}
