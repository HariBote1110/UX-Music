import Foundation

/// Minimal LRC parsing for synced on-device display (timestamp → line text).
enum LRCParser {
    struct TimedLine: Identifiable, Equatable, Sendable {
        let id: Int
        let startTime: Double
        let text: String
    }

    /// Returns timed lines sorted by `startTime`. Skips non-timestamp tags such as `[ti:…]`.
    static func parseTimedLines(_ raw: String) -> [TimedLine] {
        var out: [TimedLine] = []
        var nextId = 0
        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let trimmed = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let (seconds, remainder) = extractLeadingTimestamp(trimmed) else { continue }
            let text = remainder.trimmingCharacters(in: .whitespaces)
            nextId += 1
            out.append(TimedLine(id: nextId, startTime: seconds, text: text))
        }
        return out.sorted { $0.startTime < $1.startTime }
    }

    /// Index of the line whose `startTime` is last among those `<= time` (clamped to first line when before first timestamp).
    static func activeLineIndex(in lines: [TimedLine], at time: Double) -> Int {
        guard !lines.isEmpty else { return 0 }
        var best = 0
        for (i, line) in lines.enumerated() where line.startTime <= time {
            best = i
        }
        return best
    }

    /// `(seconds, textAfterClosingBracket)` when the line begins with a numeric timestamp tag.
    private static func extractLeadingTimestamp(_ line: String) -> (Double, String)? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let tag = String(line[line.index(after: line.startIndex) ..< close])
        let after = String(line[line.index(after: close)...])
        guard let seconds = parseTimestampTag(tag) else { return nil }
        return (seconds, after)
    }

    private static func parseTimestampTag(_ inner: String) -> Double? {
        let parts = inner.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        guard parts.allSatisfy({ $0.allSatisfy { $0.isNumber || $0 == "." } }) else { return nil }

        if parts.count == 3 {
            guard let h = Double(parts[0]), let m = Double(parts[1]), let secPart = parseSecondsFragment(parts[2]) else { return nil }
            return h * 3600 + m * 60 + secPart
        }
        guard let m = Double(parts[0]), let secPart = parseSecondsFragment(parts[1]) else { return nil }
        return m * 60 + secPart
    }

    /// Integer seconds plus optional `.xx` / `.xxx` fractional part.
    private static func parseSecondsFragment(_ s: String) -> Double? {
        if let dot = s.firstIndex(of: ".") {
            let wholeStr = String(s[..<dot])
            let fracStr = String(s[s.index(after: dot)...])
            guard let whole = Double(wholeStr) else { return nil }
            guard !fracStr.isEmpty, fracStr.allSatisfy(\.isNumber) else { return nil }
            guard let fracVal = Double(fracStr) else { return nil }
            let denom: Double
            switch fracStr.count {
            case 2: denom = 100
            case 3: denom = 1000
            default: denom = pow(10, Double(fracStr.count))
            }
            return whole + fracVal / denom
        }
        return Double(s)
    }
}
