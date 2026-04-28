import Foundation

struct SegmentMatch {
    let segmentIndex: Int
    let score: Double
}

enum LyricsAligner {
    static func align(lines: [String], segments: [DetectedSegment]) -> [AlignedLine] {
        let preparedSegments = segments.enumerated().map { index, segment in
            PreparedSegment(index: index, segment: segment)
        }
        var results = lines.enumerated().map { index, text in
            AlignedLine(
                index: index,
                text: text,
                timestamp: -1.0,
                confidence: defaultConfidence(for: text),
                source: defaultSource(for: text)
            )
        }

        var cursor = 0
        let searchWindow = 28

        for index in lines.indices {
            let line = lines[index]
            if isInterlude(line) {
                continue
            }

            let normalisedLine = normaliseText(line)
            if normalisedLine.isEmpty {
                continue
            }

            let upperBound = min(preparedSegments.count, max(cursor + 1, cursor + searchWindow))
            let candidate = bestCandidate(
                line: normalisedLine,
                segments: preparedSegments,
                range: cursor..<upperBound
            )

            guard let candidate, candidate.score >= 0.18 else {
                continue
            }

            let matchedSegment = preparedSegments[candidate.segmentIndex]
            results[index] = AlignedLine(
                index: index,
                text: line,
                timestamp: matchedSegment.segment.start,
                confidence: min(0.98, max(0.35, candidate.score)),
                source: "match"
            )
            cursor = matchedSegment.index + 1
        }

        interpolate(results: &results)
        assignInterludeTimestamps(results: &results)
        clampMonotone(results: &results)
        return results
    }

    private static func bestCandidate(
        line: String,
        segments: [PreparedSegment],
        range: Range<Int>
    ) -> SegmentMatch? {
        guard !segments.isEmpty, !range.isEmpty else {
            return nil
        }

        var best: SegmentMatch?
        for index in range {
            let score = similarityScore(line: line, segment: segments[index].normalisedText)
            if let best, best.score >= score {
                continue
            }
            best = SegmentMatch(segmentIndex: index, score: score)
        }
        return best
    }

    private static func interpolate(results: inout [AlignedLine]) {
        let anchorIndices = results.enumerated().compactMap { index, line in
            line.source == "match" && line.timestamp >= 0 ? index : nil
        }
        let step = 2.5

        if anchorIndices.isEmpty {
            var current = 0.0
            for index in results.indices {
                if isInterlude(results[index].text) {
                    continue
                }
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
            for index in stride(from: firstAnchor - 1, through: 0, by: -1) {
                if isInterlude(results[index].text) {
                    continue
                }
                let timestamp = max(0.0, results[firstAnchor].timestamp - step * offset)
                results[index] = AlignedLine(
                    index: results[index].index,
                    text: results[index].text,
                    timestamp: timestamp,
                    confidence: min(results[index].confidence, 0.35),
                    source: "interpolated"
                )
                offset += 1.0
            }
        }

        if anchorIndices.count >= 2 {
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
                    let timestamp = results[lower].timestamp + span * fraction
                    results[index] = AlignedLine(
                        index: results[index].index,
                        text: results[index].text,
                        timestamp: timestamp,
                        confidence: min(results[index].confidence, 0.35),
                        source: "interpolated"
                    )
                }
            }
        }

        if let lastAnchor = anchorIndices.last, lastAnchor < results.count - 1 {
            var offset = 1.0
            for index in (lastAnchor + 1)..<results.count {
                if isInterlude(results[index].text) {
                    continue
                }
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
            if isInterlude(results[index].text) || results[index].timestamp < 0 {
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

    private static func similarityScore(line: String, segment: String) -> Double {
        if line.isEmpty || segment.isEmpty {
            return 0.0
        }
        if segment.contains(line) || line.contains(segment) {
            return 0.99
        }

        let lineBigrams = bigrams(for: line)
        let segmentBigrams = bigrams(for: segment)
        guard !lineBigrams.isEmpty else {
            return 0.0
        }

        let overlap = lineBigrams.intersection(segmentBigrams).count
        let precision = Double(overlap) / Double(lineBigrams.count)
        let recall = Double(overlap) / Double(max(segmentBigrams.count, 1))
        return precision * 0.75 + recall * 0.25
    }

    private static func bigrams(for text: String) -> Set<String> {
        let chars = Array(text)
        guard chars.count >= 2 else {
            return text.isEmpty ? [] : [String(chars)]
        }

        var pairs: Set<String> = []
        for index in 0..<(chars.count - 1) {
            pairs.insert(String(chars[index...index + 1]))
        }
        return pairs
    }

    fileprivate static func normaliseText(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "\u{3040}"..."\u{30ff}"))
            .union(CharacterSet(charactersIn: "\u{3400}"..."\u{9fff}"))
        let filtered = folded.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(filtered)).lowercased()
    }

    private static func defaultSource(for text: String) -> String {
        isInterlude(text) ? "interlude" : "interpolated"
    }

    private static func defaultConfidence(for text: String) -> Double {
        isInterlude(text) ? 0.15 : 0.2
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

private struct PreparedSegment {
    let index: Int
    let segment: DetectedSegment
    let normalisedText: String

    init(index: Int, segment: DetectedSegment) {
        self.index = index
        self.segment = segment
        self.normalisedText = LyricsAligner.normaliseText(segment.text)
    }
}
