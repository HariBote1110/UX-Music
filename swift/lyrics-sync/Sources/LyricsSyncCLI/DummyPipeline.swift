import Foundation

struct DummyPipeline: LyricsSyncPipeline {
    let detectedBy = "swift-dummy"

    private let progress: ProgressEmitter

    init(progress: ProgressEmitter) {
        self.progress = progress
    }

    func run(request: Request) async throws -> Result {
        progress.emit(stage: "bootstrap", percent: 5.0)
        progress.emit(stage: "dummy", percent: 100.0)

        let lines = request.lines.enumerated().map { index, text in
            AlignedLine(
                index: index,
                text: text,
                timestamp: Double(index) * 0.5,
                confidence: 0.1,
                source: normaliseSource(text: text)
            )
        }

        return Result(
            success: true,
            lines: lines,
            matchedCount: 0,
            detectedBy: detectedBy,
            detectedSegments: [],
            error: nil
        )
    }

    private func normaliseSource(text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "(interlude)" || trimmed == "[interlude]" || trimmed == "[間奏]" {
            return "interlude"
        }
        return "interpolated"
    }
}
