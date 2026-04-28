import Darwin
import Foundation

struct LyricsSyncApplication {
    private let progress = ProgressEmitter()

    func run() async {
        do {
            let request = try CLIIO.readRequest()
            let configuration = RuntimeConfiguration.fromEnvironment()
            let pipeline = PipelineFactory.make(configuration: configuration, progress: progress)
            let result = try await pipeline.run(request: request)
            try CLIIO.write(result: result)
        } catch {
            CLIIO.writeFailure(error)
            Darwin.exit(1)
        }
    }
}
