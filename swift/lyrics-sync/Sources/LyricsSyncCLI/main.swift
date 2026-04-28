import Foundation
import Darwin

struct Request: Decodable {
    let songPath: String
    let lines: [String]
    let language: String?
    let profile: String?
    let allowModelDownload: Bool?
    let whisperModel: String?
}

struct AlignedLine: Encodable {
    let index: Int
    let text: String
    let timestamp: Double
    let confidence: Double
    let source: String
}

struct DetectedSegment: Encodable {
    let start: Double
    let end: Double
    let text: String
}

struct Result: Encodable {
    let success: Bool
    let lines: [AlignedLine]?
    let matchedCount: Int?
    let detectedBy: String?
    let detectedSegments: [DetectedSegment]?
    let error: String?
}

enum CLIError: Error {
    case invalidArguments
    case invalidPayload
}

@main
struct LyricsSyncCLI {
    static func main() async {
        do {
            let request = try readRequest()
            let result = try await run(request: request)
            try write(result: result)
        } catch {
            let message = String(describing: error)
            let result = Result(
                success: false,
                lines: nil,
                matchedCount: nil,
                detectedBy: "swift-sidecar",
                detectedSegments: nil,
                error: message
            )
            try? write(result: result)
            Darwin.exit(1)
        }
    }

    static func readRequest() throws -> Request {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args == ["--request", "-"] else {
            throw CLIError.invalidArguments
        }

        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else {
            throw CLIError.invalidPayload
        }
        return try JSONDecoder().decode(Request.self, from: data)
    }

    static func run(request: Request) async throws -> Result {
        emitProgress(stage: "bootstrap", percent: 5.0)

        if dummyModeEnabled() {
            emitProgress(stage: "dummy", percent: 100.0)
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
                detectedBy: "swift-dummy",
                detectedSegments: [],
                error: nil
            )
        }

        emitProgress(stage: "unsupported", percent: 100.0)
        return Result(
            success: false,
            lines: nil,
            matchedCount: nil,
            detectedBy: "swift-sidecar",
            detectedSegments: nil,
            error: "Swift/CoreML sidecar の本実装は未完了です。現時点では Python fallback を利用してください。"
        )
    }

    static func write(result: Result) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(result)
        FileHandle.standardOutput.write(data)
    }

    static func emitProgress(stage: String, percent: Double) {
        let payload = ["stage": stage, "percent": percent] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    static func dummyModeEnabled() -> Bool {
        let value = ProcessInfo.processInfo.environment["UX_MUSIC_LYRICS_SYNC_DUMMY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return value == "1" || value == "true" || value == "yes"
    }

    static func normaliseSource(text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "(interlude)" || trimmed == "[interlude]" || trimmed == "[間奏]" {
            return "interlude"
        }
        return "interpolated"
    }
}
