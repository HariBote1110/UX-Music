import Foundation

enum CLIIO {
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

    static func write(result: Result) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(result)
        FileHandle.standardOutput.write(data)
    }

    static func writeFailure(_ error: Error, detectedBy: String = "swift-sidecar") {
        let result = Result(
            success: false,
            lines: nil,
            matchedCount: nil,
            detectedBy: detectedBy,
            detectedSegments: nil,
            error: describe(error)
        )
        try? write(result: result)
    }

    private static func describe(_ error: Error) -> String {
        if let localised = error as? LocalizedError,
           let description = localised.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
