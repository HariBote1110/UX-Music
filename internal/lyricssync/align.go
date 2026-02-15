package lyricssync

import (
	"math"
	"strings"
)

const (
	defaultInterpolationStep = 2.0
	matchLookaheadWindow     = 8
	matchThreshold           = 0.28
	interludeLineWeight      = 0.22
	interludeStepScale       = 0.35
	anchorTailWeight         = 1.0
)

func alignLines(lines []string, segments []whisperSegment) ([]AlignedLine, int) {
	aligned := make([]AlignedLine, len(lines))
	segmentCursor := 0
	matchedCount := 0

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

		bestIndex, bestScore := findBestSegment(line, segments, segmentCursor, matchLookaheadWindow)
		if bestIndex >= 0 && bestScore >= matchThreshold {
			aligned[i].Timestamp = clampTimestamp(segments[bestIndex].Start)
			aligned[i].Confidence = roundTo3(bestScore)
			aligned[i].Source = "match"
			segmentCursor = bestIndex + 1
			matchedCount++
		}
	}

	interpolateMissingTimestamps(aligned)
	enforceMonotonicTimestamps(aligned)
	return aligned, matchedCount
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

	cursor := firstMatchedTS
	for i := firstMatchedIndex - 1; i >= 0; i-- {
		cursor = math.Max(0, cursor-interpolationStepForLine(typicalStep, lines[i]))
		lines[i].Timestamp = roundTo3(cursor)
	}

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

	cursor = lastMatchedTS
	for i := lastMatchedIndex + 1; i < len(lines); i++ {
		cursor += interpolationStepForLine(typicalStep, lines[i])
		lines[i].Timestamp = roundTo3(cursor)
	}
}

func fillGapByWeightedInterpolation(lines []AlignedLine, leftIndex int, rightIndex int, leftTS float64, rightTS float64, typicalStep float64) {
	indices := make([]int, 0, rightIndex-leftIndex-1)
	weights := make([]float64, 0, rightIndex-leftIndex-1)
	for i := leftIndex + 1; i < rightIndex; i++ {
		if isFinite(lines[i].Timestamp) {
			continue
		}
		indices = append(indices, i)
		weights = append(weights, interpolationWeight(lines[i]))
	}
	if len(indices) == 0 {
		return
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

	totalWeight := anchorTailWeight
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

func interpolationWeight(line AlignedLine) float64 {
	if line.Source == "interlude" {
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
