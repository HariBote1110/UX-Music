import Foundation

struct ForcedAlignerWordTiming: Equatable {
    let start: Double
    let end: Double
    let text: String

    static func parseSpeechCLIOutput(_ output: String) throws -> [ForcedAlignerWordTiming] {
        let pattern = #"^\s*\[\s*([0-9]+(?:\.[0-9]+)?)s?\s*-\s*([0-9]+(?:\.[0-9]+)?)s?\s*\]\s*(.*?)\s*$"#
        let regex = try NSRegularExpression(pattern: pattern)
        var words: [ForcedAlignerWordTiming] = []

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  match.numberOfRanges == 4,
                  let startRange = Range(match.range(at: 1), in: line),
                  let endRange = Range(match.range(at: 2), in: line),
                  let textRange = Range(match.range(at: 3), in: line),
                  let start = Double(line[startRange]),
                  let end = Double(line[endRange])
            else {
                continue
            }

            let text = String(line[textRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                continue
            }
            words.append(ForcedAlignerWordTiming(start: start, end: end, text: text))
        }

        if words.isEmpty {
            throw CLIError.unsupported("強制アラインメント出力から単語タイムスタンプを読み取れませんでした。")
        }
        return words
    }
}

enum ForcedAlignerLineMapper {
    static func transcriptText(from lines: [String]) -> String {
        lines
            .filter { !isInterlude($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func map(words: [ForcedAlignerWordTiming], to lines: [String]) -> [AlignedLine] {
        var mapped = lines.enumerated().map { index, text in
            AlignedLine(
                index: index,
                text: text,
                timestamp: -1.0,
                confidence: isInterlude(text) ? 0.15 : 0.2,
                source: isInterlude(text) ? "interlude" : "interpolated"
            )
        }

        var cursor = 0
        for index in lines.indices {
            let line = lines[index]
            if isInterlude(line) {
                continue
            }
            let target = normaliseText(line)
            if target.isEmpty {
                continue
            }

            var accumulated = ""
            var firstWordIndex: Int?
            while cursor < words.count && accumulated.count < target.count {
                let token = normaliseText(words[cursor].text)
                if !token.isEmpty {
                    if firstWordIndex == nil {
                        firstWordIndex = cursor
                    }
                    accumulated += token
                }
                cursor += 1
            }

            guard let firstWordIndex, !accumulated.isEmpty else {
                continue
            }

            mapped[index] = AlignedLine(
                index: index,
                text: line,
                timestamp: words[firstWordIndex].start,
                confidence: 0.86,
                source: "match"
            )
        }

        interpolate(results: &mapped)
        assignInterludeTimestamps(results: &mapped)
        clampMonotone(results: &mapped)
        return mapped
    }

    private static func interpolate(results: inout [AlignedLine]) {
        let anchorIndices = results.enumerated().compactMap { index, line in
            line.source == "match" && line.timestamp >= 0 ? index : nil
        }
        let step = 2.5

        if anchorIndices.isEmpty {
            var current = 0.0
            for index in results.indices where !isInterlude(results[index].text) {
                results[index] = AlignedLine(
                    index: results[index].index,
                    text: results[index].text,
                    timestamp: current,
                    confidence: min(results[index].confidence, 0.35),
                    source: "interpolated"
                )
                current += step
            }
            return
        }

        if let firstAnchor = anchorIndices.first, firstAnchor > 0 {
            var offset = 1.0
            for index in stride(from: firstAnchor - 1, through: 0, by: -1) where !isInterlude(results[index].text) {
                results[index] = AlignedLine(
                    index: results[index].index,
                    text: results[index].text,
                    timestamp: max(0.0, results[firstAnchor].timestamp - step * offset),
                    confidence: min(results[index].confidence, 0.35),
                    source: "interpolated"
                )
                offset += 1.0
            }
        }

        for pair in zip(anchorIndices, anchorIndices.dropFirst()) {
            let lower = pair.0
            let upper = pair.1
            let gapIndices = (lower + 1..<upper).filter {
                !isInterlude(results[$0].text) && results[$0].timestamp < 0
            }
            guard !gapIndices.isEmpty else {
                continue
            }

            let span = max(0.001, results[upper].timestamp - results[lower].timestamp)
            for (rank, index) in gapIndices.enumerated() {
                let fraction = Double(rank + 1) / Double(gapIndices.count + 1)
                results[index] = AlignedLine(
                    index: results[index].index,
                    text: results[index].text,
                    timestamp: results[lower].timestamp + span * fraction,
                    confidence: min(results[index].confidence, 0.35),
                    source: "interpolated"
                )
            }
        }

        if let lastAnchor = anchorIndices.last, lastAnchor < results.count - 1 {
            var offset = 1.0
            for index in (lastAnchor + 1)..<results.count where !isInterlude(results[index].text) {
                results[index] = AlignedLine(
                    index: results[index].index,
                    text: results[index].text,
                    timestamp: results[lastAnchor].timestamp + step * offset,
                    confidence: min(results[index].confidence, 0.35),
                    source: "interpolated"
                )
                offset += 1.0
            }
        }
    }

    private static func assignInterludeTimestamps(results: inout [AlignedLine]) {
        let step = 2.5

        for index in results.indices where isInterlude(results[index].text) {
            let previous = results[..<index].last { $0.timestamp >= 0 && !isInterlude($0.text) }
            let next = (index + 1 < results.count)
                ? results[(index + 1)...].first { $0.timestamp >= 0 && !isInterlude($0.text) }
                : nil

            let timestamp: Double
            if let previous, let next {
                timestamp = max(previous.timestamp, (previous.timestamp + next.timestamp) / 2.0)
            } else if let previous {
                timestamp = previous.timestamp + step
            } else if let next {
                timestamp = max(0.0, next.timestamp - step)
            } else {
                timestamp = 0.0
            }

            results[index] = AlignedLine(
                index: results[index].index,
                text: results[index].text,
                timestamp: timestamp,
                confidence: 0.15,
                source: "interlude"
            )
        }
    }

    private static func clampMonotone(results: inout [AlignedLine]) {
        var lastTimestamp: Double?
        for index in results.indices {
            if results[index].timestamp < 0 {
                continue
            }
            if let lastTimestamp, results[index].timestamp < lastTimestamp {
                results[index] = AlignedLine(
                    index: results[index].index,
                    text: results[index].text,
                    timestamp: lastTimestamp + 0.5,
                    confidence: min(results[index].confidence, 0.72),
                    source: results[index].source
                )
            }
            lastTimestamp = results[index].timestamp
        }
    }

    private static func normaliseText(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "\u{3040}"..."\u{30ff}"))
            .union(CharacterSet(charactersIn: "\u{3400}"..."\u{9fff}"))
        let filtered = folded.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(filtered)).lowercased()
    }

    private static func isInterlude(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ||
            trimmed == "(interlude)" ||
            trimmed == "[interlude]" ||
            trimmed == "[間奏]" ||
            trimmed == "interlude" ||
            trimmed == "[instrumental]"
    }
}

struct Qwen3ForcedAlignerPipeline: LyricsSyncPipeline {
    let detectedBy = "swift-qwen3-forced-aligner"

    private let configuration: RuntimeConfiguration
    private let progress: ProgressEmitter

    init(configuration: RuntimeConfiguration, progress: ProgressEmitter) {
        self.configuration = configuration
        self.progress = progress
    }

    var isAvailable: Bool {
        resolveBinary() != nil
    }

    func run(request: Request) async throws -> Result {
        guard FileManager.default.fileExists(atPath: request.songPath) else {
            throw CLIError.invalidSongPath(request.songPath)
        }
        let transcript = ForcedAlignerLineMapper.transcriptText(from: request.lines)
        guard !transcript.isEmpty else {
            throw CLIError.noLyricsLines
        }
        guard let binary = resolveBinary() else {
            throw CLIError.unsupported("Qwen3 Forced Aligner CLI が見つかりません。`brew install soniqo/tap/speech` または UX_MUSIC_LYRICS_SYNC_ALIGNER_BIN を設定してください。")
        }

        progress.emit(stage: "forced_align_start", percent: 8.0)
        let output = try runSpeechAligner(binary: binary, request: request, transcript: transcript)
        progress.emit(stage: "forced_align_parse", percent: 70.0)
        let words = try ForcedAlignerWordTiming.parseSpeechCLIOutput(output)
        let alignedLines = ForcedAlignerLineMapper.map(words: words, to: request.lines)
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
            detectedSegments: detectedSegments(from: alignedLines, lastWordEnd: words.last?.end),
            error: nil
        )
    }

    private func runSpeechAligner(binary: String, request: Request, transcript: String) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: binary)

        var arguments = [
            "align",
            request.songPath,
            "--text",
            transcript,
        ]
        if let language = languageHint(from: request.language) {
            arguments.append(contentsOf: ["--language", language])
        }
        if let model = configuration.forcedAlignerModel {
            arguments.append(contentsOf: ["--aligner-model", model])
        }
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        progress.emit(stage: "forced_align_run", percent: 35.0)
        process.waitUntilExit()

        let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw CLIError.unsupported(
                "Qwen3 Forced Aligner が失敗しました (exit \(process.terminationStatus)): \(String(stderrText.prefix(800)))"
            )
        }
        guard !stdoutText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError.unsupported("Qwen3 Forced Aligner が空の結果を返しました。\(String(stderrText.prefix(400)))")
        }
        return stdoutText
    }

    private func resolveBinary() -> String? {
        if let configured = configuration.forcedAlignerBinary {
            if FileManager.default.isExecutableFile(atPath: configured) {
                return configured
            }
            return nil
        }
        return lookupExecutable(named: "speech")
    }

    private func lookupExecutable(named name: String) -> String? {
        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in pathValue.split(separator: ":") {
            let candidate = URL(filePath: String(directory)).appending(path: name).path()
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func languageHint(from raw: String?) -> String? {
        let clean = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

    private func detectedSegments(from lines: [AlignedLine], lastWordEnd: Double?) -> [DetectedSegment] {
        var segments: [DetectedSegment] = []
        for index in lines.indices where lines[index].source == "match" {
            let next = lines[(index + 1)..<lines.count].first { $0.timestamp > lines[index].timestamp }
            let end = next?.timestamp ?? lastWordEnd ?? lines[index].timestamp
            segments.append(
                DetectedSegment(
                    start: lines[index].timestamp,
                    end: max(lines[index].timestamp, end),
                    text: lines[index].text
                )
            )
        }
        return segments
    }
}
