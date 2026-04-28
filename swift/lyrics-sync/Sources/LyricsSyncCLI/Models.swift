import Foundation

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
    case invalidSongPath(String)
    case noLyricsLines
    case transcriptionFailed
    case unsupported(String)
}

extension CLIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "`lyrics-sync-swift --request -` の形式で実行してください。"
        case .invalidPayload:
            return "stdin から有効な JSON request を受け取れませんでした。"
        case .invalidSongPath(let path):
            return "音声ファイルが見つかりません: \(path)"
        case .noLyricsLines:
            return "歌詞行が空です。"
        case .transcriptionFailed:
            return "WhisperKit から有効なセグメントを取得できませんでした。"
        case .unsupported(let message):
            return message
        }
    }
}
