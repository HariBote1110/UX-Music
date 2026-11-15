import Foundation

/// One timed lyric line paired with its optional Japanese translation. Mirrors `LRCParser.TimedLine`
/// plus a `translation`. Conforms to `LyricsTimedLine` so it shares `LRCParser.activeLineIndex`'s
/// active-line rule instead of duplicating it.
struct TranslatedTimedLine: Identifiable, Equatable, Sendable, LyricsTimedLine {
    let id: Int
    let startTime: Double
    let text: String
    let translation: String?
}

/// One plain (untimed) lyric line paired with its optional Japanese translation.
struct TranslatedPlainLine: Equatable, Sendable {
    let text: String
    let translation: String?
}

/// Merges a primary (English/original) lyric source with its `.ja.lrc` / `.ja.txt` sidecar, porting
/// the desktop's `src/renderer/js/features/lyrics-translation.ts` rules so the mobile app's 和訳
/// display matches the desktop's exactly:
///
/// - Timed LRC + `.ja.lrc`: matched by timestamp (rounded to milliseconds), falling back to
///   positional (same index) when no timestamp matches.
/// - Timed LRC + `.ja.txt`: matched positionally (line *i* of the translation pairs with timed
///   line *i*).
/// - Plain `.txt` + `.ja.txt`: matched positionally.
/// - Blank/interlude primary lines (empty, or the literal markers `[間奏]` / `[interlude]` /
///   `(interlude)`) never receive a translation, even if the sidecar has text at that position.
enum LyricsTranslationMerger {
    private static let interludeMarkers: Set<String> = ["[間奏]", "[interlude]", "(interlude)"]

    /// `true` when `text` is blank/whitespace-only, or one of the literal interlude markers older
    /// saved files carry instead of a blank line.
    static func isInterludeText(_ text: String?) -> Bool {
        guard let text else { return true }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return interludeMarkers.contains(trimmed.lowercased())
    }

    /// Rounds a timestamp to milliseconds so floating-point LRC parsing doesn't cause spurious
    /// timestamp mismatches between the primary and translation files.
    private static func timeKey(_ time: Double) -> Double {
        (time * 1000).rounded() / 1000
    }

    private static func nonBlankOrNil(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Merges a timed primary lyric with a timed `.ja.lrc` translation.
    static func mergeTimedWithJaLRC(
        primary: [LRCParser.TimedLine],
        translation: [LRCParser.TimedLine]
    ) -> [TranslatedTimedLine] {
        // Several lines may share one timestamp. Each time group pairs its translations with its
        // primary lines in order: positionally when the counts match (blank primary lines consume
        // their slot), otherwise non-blank translations with non-blank primary lines.
        var translationsByTime: [Double: [String]] = [:]
        for line in translation {
            translationsByTime[timeKey(line.startTime), default: []].append(line.text)
        }
        var primaryIndicesByTime: [Double: [Int]] = [:]
        for (index, line) in primary.enumerated() {
            primaryIndicesByTime[timeKey(line.startTime), default: []].append(index)
        }
        var picks: [Int: String] = [:]
        for (key, indices) in primaryIndicesByTime {
            guard let texts = translationsByTime[key] else { continue }
            if texts.count == indices.count {
                for (slot, index) in indices.enumerated() {
                    picks[index] = texts[slot]
                }
            } else {
                let nonBlankPrimary = indices.filter { !isInterludeText(primary[$0].text) }
                let nonBlankTexts = texts.filter { nonBlankOrNil($0) != nil }
                for (index, text) in zip(nonBlankPrimary, nonBlankTexts) {
                    picks[index] = text
                }
            }
        }
        return primary.enumerated().map { index, line in
            guard !isInterludeText(line.text) else {
                return TranslatedTimedLine(id: line.id, startTime: line.startTime, text: line.text, translation: nil)
            }
            let fromIndex = index < translation.count ? translation[index].text : nil
            return TranslatedTimedLine(
                id: line.id,
                startTime: line.startTime,
                text: line.text,
                translation: nonBlankOrNil(picks[index] ?? fromIndex)
            )
        }
    }

    /// Merges a timed primary lyric with a positional (plain-text) `.ja.txt` translation — one
    /// translated row per timed primary line, in order.
    static func mergeTimedWithJaTxt(primary: [LRCParser.TimedLine], translationText: String) -> [TranslatedTimedLine] {
        let rows = translationText.components(separatedBy: "\n")
        return primary.enumerated().map { index, line in
            guard !isInterludeText(line.text) else {
                return TranslatedTimedLine(id: line.id, startTime: line.startTime, text: line.text, translation: nil)
            }
            let row = index < rows.count ? rows[index] : nil
            return TranslatedTimedLine(id: line.id, startTime: line.startTime, text: line.text, translation: nonBlankOrNil(row))
        }
    }

    /// Merges a plain (untimed) primary lyric with a positional `.ja.txt` translation, line by line.
    static func mergePlainWithJaTxt(primaryText: String, translationText: String) -> [TranslatedPlainLine] {
        let primaryRows = primaryText.components(separatedBy: "\n")
        let translationRows = translationText.components(separatedBy: "\n")
        let count = max(primaryRows.count, translationRows.count)
        guard count > 0 else { return [] }
        var out: [TranslatedPlainLine] = []
        out.reserveCapacity(count)
        for index in 0 ..< count {
            let rawText = index < primaryRows.count ? primaryRows[index] : ""
            let text = rawText.trimmingCharacters(in: .whitespaces).isEmpty ? " " : rawText
            var translation = index < translationRows.count ? nonBlankOrNil(translationRows[index]) : nil
            if isInterludeText(text) { translation = nil }
            out.append(TranslatedPlainLine(text: text, translation: translation))
        }
        return out
    }
}
