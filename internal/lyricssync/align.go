package lyricssync

import (
	"math"
	"sort"
	"strings"
)

const (
	defaultInterpolationStep = 2.0
	matchLookaheadWindow     = 8
	matchThreshold           = 0.28
	interludeLineWeight      = 0.22
	interludeTinyWeight      = 0.03
	interludeStepScale       = 0.35
	anchorTailWeight         = 1.0
	leadingAnchorTailWeight  = 0.2
	interludeOnlyTailWeight  = 0.05
)

func alignLines(lines []string, segments []whisperSegment) ([]AlignedLine, int) {
	aligned := make([]AlignedLine, len(lines))
	lyricLineIndexes := make([]int, 0, len(lines))
	lyricLines := make([]AlignedLine, 0, len(lines))
	segmentAnchors := buildSegmentAnchors(segments)

	for i, line := range lines {
		aligned[i] = AlignedLine{
			Index:      i,
			Text:       line,
			Timestamp:  math.NaN(),
			Confidence: 0,
			Source:     "interpolated",
		}

		if isInterludeLine(line) {
			aligned[i].Source = "interlude"
			continue
		}
		lyricLineIndexes = append(lyricLineIndexes, i)
		lyricLines = append(lyricLines, aligned[i])
	}

	if len(lyricLines) == 0 {
		interpolateMissingTimestamps(aligned)
		enforceMonotonicTimestamps(aligned)
		return aligned, 0
	}

	segmentCursor := 0
	matchedCount := 0
	for i := range lyricLines {
		bestIndex, bestScore := findBestSegment(lyricLines[i].Text, segments, segmentCursor, matchLookaheadWindow)
		if bestIndex >= 0 && bestScore >= matchThreshold {
			anchor := segments[bestIndex].Start
			if bestIndex >= 0 && bestIndex < len(segmentAnchors) {
				anchor = segmentAnchors[bestIndex]
			}
			lyricLines[i].Timestamp = clampTimestamp(anchor)
			lyricLines[i].Confidence = roundTo3(bestScore)
			lyricLines[i].Source = "match"
			segmentCursor = bestIndex + 1
			matchedCount++
		}
	}

	interpolateMissingTimestamps(lyricLines)
	for i, lineIndex := range lyricLineIndexes {
		aligned[lineIndex].Timestamp = lyricLines[i].Timestamp
		aligned[lineIndex].Confidence = lyricLines[i].Confidence
		aligned[lineIndex].Source = lyricLines[i].Source
	}

	fillInterludeTimestamps(aligned)
	enforceMonotonicTimestamps(aligned)
	return aligned, matchedCount
}

func fillInterludeTimestamps(lines []AlignedLine) {
	if len(lines) == 0 {
		return
	}

	typicalStep := estimateTypicalStep(lines)
	if typicalStep <= 0 {
		typicalStep = defaultInterpolationStep
	}

	for i := 0; i < len(lines); {
		if lines[i].Source != "interlude" || isFinite(lines[i].Timestamp) {
			i++
			continue
		}

		start := i
		end := i
		for end+1 < len(lines) && lines[end+1].Source == "interlude" && !isFinite(lines[end+1].Timestamp) {
			end++
		}

		leftIndex := findPrevFiniteTimestampIndex(lines, start-1)
		rightIndex := findNextFiniteTimestampIndex(lines, end+1)

		switch {
		case leftIndex >= 0 && rightIndex >= 0:
			fillGapWithRangeAndTailWeight(lines, start, rightIndex, lines[leftIndex].Timestamp, lines[rightIndex].Timestamp, typicalStep, interludeOnlyTailWeight)
		case leftIndex < 0 && rightIndex >= 0:
			rightTS := lines[rightIndex].Timestamp
			if start == 0 {
				lines[0].Timestamp = 0
				if start < end {
					fillGapWithRangeAndTailWeight(lines, start+1, rightIndex, 0, rightTS, typicalStep, interludeOnlyTailWeight)
				}
			} else {
				fillGapWithRangeAndTailWeight(lines, start, rightIndex, 0, rightTS, typicalStep, interludeOnlyTailWeight)
			}
		case leftIndex >= 0:
			cursor := lines[leftIndex].Timestamp
			for j := start; j <= end; j++ {
				cursor += interpolationStepForLine(typicalStep, lines[j])
				lines[j].Timestamp = roundTo3(cursor)
			}
		default:
			cursor := 0.0
			for j := start; j <= end; j++ {
				if j == 0 {
					lines[j].Timestamp = 0
					continue
				}
				cursor += interpolationStepForLine(typicalStep, lines[j])
				lines[j].Timestamp = roundTo3(cursor)
			}
		}

		i = end + 1
	}
}

func findPrevFiniteTimestampIndex(lines []AlignedLine, from int) int {
	for i := from; i >= 0; i-- {
		if isFinite(lines[i].Timestamp) {
			return i
		}
	}
	return -1
}

func findNextFiniteTimestampIndex(lines []AlignedLine, from int) int {
	for i := from; i < len(lines); i++ {
		if isFinite(lines[i].Timestamp) {
			return i
		}
	}
	return -1
}

func findBestSegment(line string, segments []whisperSegment, start int, lookahead int) (int, float64) {
	if len(segments) == 0 {
		return -1, 0
	}
	if start < 0 {
		start = 0
	}
	if start >= len(segments) {
		return -1, 0
	}

	lineText := normaliseText(line)
	if lineText == "" {
		return -1, 0
	}

	bestIndex := -1
	bestScore := 0.0
	end := start + lookahead
	if end > len(segments) {
		end = len(segments)
	}

	for i := start; i < end; i++ {
		segmentText := normaliseText(segments[i].Text)
		if segmentText == "" {
			continue
		}

		score := textSimilarity(lineText, segmentText)
		if score > bestScore {
			bestScore = score
			bestIndex = i
		}
	}

	return bestIndex, bestScore
}

func buildSegmentAnchors(segments []whisperSegment) []float64 {
	anchors := make([]float64, len(segments))
	for i, segment := range segments {
		anchors[i] = clampTimestamp(segment.Start)
	}
	if len(segments) == 0 {
		return anchors
	}

	cps := estimateSegmentCharRate(segments)
	first := segments[0]
	duration := first.End - first.Start
	if first.Start > 0.2 || duration <= 0 {
		return anchors
	}

	textLen := normalisedRuneCount(first.Text)
	if textLen <= 1 {
		return anchors
	}

	expected := clampFloat(float64(textLen)/cps, 0.8, 8.0)
	// 先頭セグメントが異常に長い場合のみ、無音区間を削る。
	if duration < expected*1.7 || duration < 6.0 {
		return anchors
	}

	trimmedStart := first.End - expected
	if trimmedStart < first.Start {
		trimmedStart = first.Start
	}
	anchors[0] = clampTimestamp(trimmedStart)
	return anchors
}

func estimateSegmentCharRate(segments []whisperSegment) float64 {
	rates := make([]float64, 0, len(segments))
	for _, segment := range segments {
		duration := segment.End - segment.Start
		if duration <= 0.2 || duration > 30 {
			continue
		}

		textLen := normalisedRuneCount(segment.Text)
		if textLen <= 1 {
			continue
		}

		rate := float64(textLen) / duration
		if rate < 0.5 || rate > 25 {
			continue
		}
		rates = append(rates, rate)
	}

	if len(rates) == 0 {
		return 4.2
	}
	sort.Float64s(rates)

	median := 0.0
	n := len(rates)
	if n%2 == 1 {
		median = rates[n/2]
	} else {
		median = (rates[n/2-1] + rates[n/2]) / 2
	}

	return clampFloat(median, 2.5, 8.5)
}

func normalisedRuneCount(text string) int {
	return len([]rune(normaliseText(text)))
}

func textSimilarity(a string, b string) float64 {
	if a == "" || b == "" {
		return 0
	}
	if a == b {
		return 1
	}

	dice := diceCoefficient(a, b)

	containsScore := 0.0
	if strings.Contains(a, b) || strings.Contains(b, a) {
		minLen := float64(minInt(len([]rune(a)), len([]rune(b))))
		maxLen := float64(maxInt(len([]rune(a)), len([]rune(b))))
		if maxLen > 0 {
			containsScore = 0.3 + 0.7*(minLen/maxLen)
		}
	}

	if containsScore > dice {
		return containsScore
	}
	return dice
}

func diceCoefficient(a string, b string) float64 {
	runesA := []rune(a)
	runesB := []rune(b)

	if len(runesA) == 0 || len(runesB) == 0 {
		return 0
	}
	if len(runesA) == 1 || len(runesB) == 1 {
		if runesA[0] == runesB[0] {
			return 1
		}
		return 0
	}

	bigramsA := make(map[string]int)
	for i := 0; i < len(runesA)-1; i++ {
		bg := string(runesA[i : i+2])
		bigramsA[bg]++
	}

	bigramsB := make(map[string]int)
	for i := 0; i < len(runesB)-1; i++ {
		bg := string(runesB[i : i+2])
		bigramsB[bg]++
	}

	intersection := 0
	for bg, countA := range bigramsA {
		if countB, ok := bigramsB[bg]; ok {
			intersection += minInt(countA, countB)
		}
	}

	total := 0
	for _, countA := range bigramsA {
		total += countA
	}
	for _, countB := range bigramsB {
		total += countB
	}
	if total == 0 {
		return 0
	}

	return (2.0 * float64(intersection)) / float64(total)
}

func interpolateMissingTimestamps(lines []AlignedLine) {
	typicalStep := estimateTypicalStep(lines)
	if typicalStep <= 0 {
		typicalStep = defaultInterpolationStep
	}

	firstMatchedIndex := -1
	firstMatchedTS := 0.0
	for i := range lines {
		if isFinite(lines[i].Timestamp) {
			firstMatchedIndex = i
			firstMatchedTS = lines[i].Timestamp
			break
		}
	}

	if firstMatchedIndex == -1 {
		cursor := 0.0
		for i := range lines {
			if i == 0 {
				lines[i].Timestamp = 0
				continue
			}
			cursor += interpolationStepForLine(typicalStep, lines[i])
			lines[i].Timestamp = roundTo3(cursor)
		}
		return
	}

	fillLeadingBeforeFirstMatch(lines, firstMatchedIndex, firstMatchedTS, typicalStep)

	lastMatchedIndex := firstMatchedIndex
	lastMatchedTS := firstMatchedTS
	for i := firstMatchedIndex + 1; i < len(lines); i++ {
		if !isFinite(lines[i].Timestamp) {
			continue
		}

		currentMatchedIndex := i
		currentMatchedTS := lines[i].Timestamp
		gap := currentMatchedIndex - lastMatchedIndex
		if gap > 1 {
			fillGapByWeightedInterpolation(lines, lastMatchedIndex, currentMatchedIndex, lastMatchedTS, currentMatchedTS, typicalStep)
		}

		lastMatchedIndex = currentMatchedIndex
		lastMatchedTS = currentMatchedTS
	}

	cursor := lastMatchedTS
	for i := lastMatchedIndex + 1; i < len(lines); i++ {
		cursor += interpolationStepForLine(typicalStep, lines[i])
		lines[i].Timestamp = roundTo3(cursor)
	}
}

func fillLeadingBeforeFirstMatch(lines []AlignedLine, firstMatchedIndex int, firstMatchedTS float64, typicalStep float64) {
	if firstMatchedIndex <= 0 {
		return
	}

	if firstMatchedTS <= 0 {
		cursor := firstMatchedTS
		for i := firstMatchedIndex - 1; i >= 0; i-- {
			cursor = math.Max(0, cursor-interpolationStepForLine(typicalStep, lines[i]))
			lines[i].Timestamp = roundTo3(cursor)
		}
		return
	}

	start := 0
	anchorTS := 0.0
	hasLeadingInterlude := false
	if lines[0].Source == "interlude" {
		lines[0].Timestamp = 0
		start = 1
		anchorTS = 0
		hasLeadingInterlude = true
	}

	if start >= firstMatchedIndex {
		return
	}

	tailWeight := anchorTailWeight
	if hasLeadingInterlude {
		tailWeight = leadingAnchorTailWeight
	}
	fillGapWithRangeAndTailWeight(lines, start, firstMatchedIndex, anchorTS, firstMatchedTS, typicalStep, tailWeight)
}

func fillGapByWeightedInterpolation(lines []AlignedLine, leftIndex int, rightIndex int, leftTS float64, rightTS float64, typicalStep float64) {
	fillGapWithRangeAndTailWeight(lines, leftIndex+1, rightIndex, leftTS, rightTS, typicalStep, anchorTailWeight)
}

func fillGapWithRange(lines []AlignedLine, startIndex int, rightAnchorIndex int, leftTS float64, rightTS float64, typicalStep float64) {
	fillGapWithRangeAndTailWeight(lines, startIndex, rightAnchorIndex, leftTS, rightTS, typicalStep, anchorTailWeight)
}

func fillGapWithRangeAndTailWeight(lines []AlignedLine, startIndex int, rightAnchorIndex int, leftTS float64, rightTS float64, typicalStep float64, tailWeight float64) {
	indices := make([]int, 0, maxInt(0, rightAnchorIndex-startIndex))
	hasLyricGap := false
	for i := startIndex; i < rightAnchorIndex; i++ {
		if isFinite(lines[i].Timestamp) {
			continue
		}
		indices = append(indices, i)
		if lines[i].Source != "interlude" {
			hasLyricGap = true
		}
	}
	if len(indices) == 0 {
		return
	}

	weights := make([]float64, 0, len(indices))
	for _, idx := range indices {
		weights = append(weights, interpolationWeight(lines[idx], hasLyricGap))
	}

	span := rightTS - leftTS
	if span <= 0 {
		cursor := leftTS
		for _, idx := range indices {
			cursor += interpolationStepForLine(typicalStep, lines[idx])
			lines[idx].Timestamp = roundTo3(cursor)
		}
		return
	}

	if tailWeight <= 0 {
		tailWeight = anchorTailWeight
	}
	if !hasLyricGap && tailWeight > interludeOnlyTailWeight {
		tailWeight = interludeOnlyTailWeight
	}

	totalWeight := tailWeight
	for _, weight := range weights {
		totalWeight += weight
	}
	if totalWeight <= 0 {
		totalWeight = float64(len(indices) + 1)
		weights = make([]float64, len(indices))
		for i := range weights {
			weights[i] = 1
		}
	}

	cumulative := 0.0
	for i, idx := range indices {
		cumulative += weights[i]
		ratio := cumulative / totalWeight
		lines[idx].Timestamp = roundTo3(leftTS + span*ratio)
	}
}

func interpolationWeight(line AlignedLine, hasLyricGap bool) float64 {
	if line.Source == "interlude" {
		if hasLyricGap {
			return interludeTinyWeight
		}
		return interludeLineWeight
	}
	return 1.0
}

func interpolationStepForLine(typicalStep float64, line AlignedLine) float64 {
	if line.Source == "interlude" {
		return typicalStep * interludeStepScale
	}
	return typicalStep
}

func enforceMonotonicTimestamps(lines []AlignedLine) {
	last := -0.01
	for i := range lines {
		ts := lines[i].Timestamp
		if !isFinite(ts) || ts < 0 {
			ts = 0
		}
		if ts <= last {
			ts = last + 0.01
			if lines[i].Source == "match" {
				lines[i].Source = "interpolated"
			}
		}
		lines[i].Timestamp = roundTo3(ts)
		last = ts
	}
}

func estimateTypicalStep(lines []AlignedLine) float64 {
	prevIdx := -1
	prevTS := 0.0
	total := 0.0
	count := 0.0

	for i := range lines {
		if !isFinite(lines[i].Timestamp) || lines[i].Source != "match" {
			continue
		}
		if prevIdx >= 0 {
			gapIdx := float64(i - prevIdx)
			gapTS := lines[i].Timestamp - prevTS
			if gapIdx > 0 && gapTS > 0 {
				total += gapTS / gapIdx
				count++
			}
		}
		prevIdx = i
		prevTS = lines[i].Timestamp
	}

	if count == 0 {
		return defaultInterpolationStep
	}

	step := total / count
	if step < 0.2 {
		return 0.2
	}
	if step > 8 {
		return 8
	}
	return step
}

func clampTimestamp(v float64) float64 {
	if v < 0 {
		return 0
	}
	return roundTo3(v)
}

func roundTo3(v float64) float64 {
	return math.Round(v*1000) / 1000
}

func isFinite(v float64) bool {
	return !math.IsNaN(v) && !math.IsInf(v, 0)
}

func minInt(a int, b int) int {
	if a < b {
		return a
	}
	return b
}

func maxInt(a int, b int) int {
	if a > b {
		return a
	}
	return b
}

func clampFloat(v float64, minValue float64, maxValue float64) float64 {
	if v < minValue {
		return minValue
	}
	if v > maxValue {
		return maxValue
	}
	return v
}
