package lyricssync

import (
	"math"
	"testing"
)

func TestAlignLinesMonotonic(t *testing.T) {
	lines := []string{
		"hello",
		"world",
		"[間奏]",
		"again",
	}
	segments := []whisperSegment{
		{Start: 0.5, End: 1.0, Text: "hello"},
		{Start: 1.6, End: 2.1, Text: "world"},
		{Start: 3.0, End: 3.5, Text: "again"},
	}

	aligned, matched := alignLines(lines, segments)
	if matched < 3 {
		t.Fatalf("matched=%d, want at least 3", matched)
	}
	if len(aligned) != len(lines) {
		t.Fatalf("len(aligned)=%d, want %d", len(aligned), len(lines))
	}

	last := -1.0
	for i, line := range aligned {
		if line.Timestamp < 0 {
			t.Fatalf("index=%d timestamp is negative: %f", i, line.Timestamp)
		}
		if line.Timestamp <= last {
			t.Fatalf("timestamps must be strictly increasing: prev=%f current=%f", last, line.Timestamp)
		}
		last = line.Timestamp
	}
}

func TestAlignLinesInterpolatesWhenNoMatch(t *testing.T) {
	lines := []string{"a", "b", "c"}
	segments := []whisperSegment{
		{Start: 10.0, End: 10.5, Text: "zzz"},
	}

	aligned, matched := alignLines(lines, segments)
	if matched != 0 {
		t.Fatalf("matched=%d, want 0", matched)
	}
	if len(aligned) != 3 {
		t.Fatalf("len(aligned)=%d, want 3", len(aligned))
	}
	if aligned[0].Timestamp != 0 {
		t.Fatalf("first timestamp=%f, want 0", aligned[0].Timestamp)
	}
	if aligned[1].Timestamp <= aligned[0].Timestamp || aligned[2].Timestamp <= aligned[1].Timestamp {
		t.Fatalf("interpolated timestamps are not increasing: %+v", aligned)
	}
}

func TestInterludeWeightedInterpolationWithinGap(t *testing.T) {
	lines := []AlignedLine{
		{Index: 0, Text: "A", Timestamp: 0, Source: "match"},
		{Index: 1, Text: "", Timestamp: math.NaN(), Source: "interlude"},
		{Index: 2, Text: "B", Timestamp: math.NaN(), Source: "interpolated"},
		{Index: 3, Text: "C", Timestamp: 8, Source: "match"},
	}

	interpolateMissingTimestamps(lines)

	if !isFinite(lines[1].Timestamp) || !isFinite(lines[2].Timestamp) {
		t.Fatalf("timestamps should be finite: %+v", lines)
	}
	if lines[1].Timestamp >= lines[2].Timestamp {
		t.Fatalf("interlude line should stay earlier than lyric line: %+v", lines)
	}
	if lines[1].Timestamp > 2.0 {
		t.Fatalf("interlude line consumed too much span: %+v", lines)
	}
	if lines[2].Timestamp >= 8.0 {
		t.Fatalf("lyric line must remain before right anchor: %+v", lines)
	}
}

func TestInterludeStepIsSmallerWithoutMatches(t *testing.T) {
	lines := []AlignedLine{
		{Index: 0, Text: "first", Timestamp: math.NaN(), Source: "interpolated"},
		{Index: 1, Text: "", Timestamp: math.NaN(), Source: "interlude"},
		{Index: 2, Text: "second", Timestamp: math.NaN(), Source: "interpolated"},
	}

	interpolateMissingTimestamps(lines)

	stepInterlude := lines[1].Timestamp - lines[0].Timestamp
	stepLyric := lines[2].Timestamp - lines[1].Timestamp
	if stepInterlude >= stepLyric {
		t.Fatalf("expected interlude step to be smaller: interlude=%f lyric=%f", stepInterlude, stepLyric)
	}
}

func TestLeadingInterludeAnchorsAtZero(t *testing.T) {
	lines := []string{
		"",
		"first lyric",
		"second lyric",
	}
	segments := []whisperSegment{
		{Start: 12.0, End: 13.0, Text: "first lyric"},
		{Start: 16.0, End: 17.0, Text: "second lyric"},
	}

	aligned, matched := alignLines(lines, segments)
	if matched < 2 {
		t.Fatalf("matched=%d, want at least 2", matched)
	}
	if aligned[0].Timestamp != 0 {
		t.Fatalf("leading interlude timestamp=%f, want 0", aligned[0].Timestamp)
	}
	if aligned[1].Timestamp < 11.5 {
		t.Fatalf("first lyric should preserve intro gap: %+v", aligned)
	}
	if aligned[2].Timestamp <= aligned[1].Timestamp {
		t.Fatalf("timestamps should increase: %+v", aligned)
	}
}

func TestLeadingLongSegmentTrimsSilenceForFirstLyric(t *testing.T) {
	lines := []string{
		"",
		"目を離しただけで",
		"儚さと脆さが",
	}
	segments := []whisperSegment{
		{Start: 0.0, End: 22.39, Text: "目を話しただけで消えてしまうような"},
		{Start: 22.39, End: 29.80, Text: "儚さともろさが愛しく思えた"},
	}

	aligned, matched := alignLines(lines, segments)
	if matched < 2 {
		t.Fatalf("matched=%d, want at least 2", matched)
	}
	if aligned[0].Timestamp != 0 {
		t.Fatalf("leading interlude should stay at zero: %+v", aligned)
	}
	if aligned[1].Timestamp <= 10.0 {
		t.Fatalf("first lyric is still too early: %+v", aligned)
	}
	if aligned[1].Timestamp >= aligned[2].Timestamp {
		t.Fatalf("timestamps should increase: %+v", aligned)
	}
}

func TestLeadingUnmatchedLyricIsNotDraggedByInterlude(t *testing.T) {
	lines := []string{
		"",
		"未一致の歌詞",
		"一致する歌詞",
	}
	segments := []whisperSegment{
		{Start: 0.0, End: 24.0, Text: "別の内容です"},
		{Start: 24.0, End: 30.0, Text: "一致する歌詞"},
	}

	aligned, matched := alignLines(lines, segments)
	if matched < 1 {
		t.Fatalf("matched=%d, want at least 1", matched)
	}
	if aligned[0].Timestamp != 0 {
		t.Fatalf("leading interlude should stay at zero: %+v", aligned)
	}
	if aligned[1].Timestamp <= 15.0 {
		t.Fatalf("unmatched lyric should stay near right anchor: %+v", aligned)
	}
	if aligned[1].Timestamp >= aligned[2].Timestamp {
		t.Fatalf("timestamps should increase: %+v", aligned)
	}
}

func TestInterludeOnlyGapIsPlacedNearRightAnchor(t *testing.T) {
	lines := []string{
		"line A",
		"",
		"line B",
	}
	segments := []whisperSegment{
		{Start: 40.0, End: 46.0, Text: "line A"},
		{Start: 53.0, End: 59.0, Text: "line B"},
	}

	aligned, matched := alignLines(lines, segments)
	if matched < 2 {
		t.Fatalf("matched=%d, want at least 2", matched)
	}
	if aligned[1].Timestamp <= 47.0 {
		t.Fatalf("interlude line should not jump immediately after previous lyric: %+v", aligned)
	}
	if aligned[1].Timestamp >= aligned[2].Timestamp {
		t.Fatalf("timestamps should increase: %+v", aligned)
	}
}

func TestUnmatchedLyricDoesNotSkipToFollowingInterlude(t *testing.T) {
	lines := []string{
		"line1",
		"line2",
		"line3",
		"line4",
		"",
		"line5",
	}
	segments := []whisperSegment{
		{Start: 34.0, End: 40.0, Text: "line1"},
		{Start: 40.0, End: 46.0, Text: "line2"},
		{Start: 46.0, End: 50.0, Text: "line3"},
		{Start: 53.0, End: 59.0, Text: "line5"},
	}

	aligned, matched := alignLines(lines, segments)
	if matched < 4 {
		t.Fatalf("matched=%d, want at least 4", matched)
	}
	if aligned[3].Timestamp <= aligned[2].Timestamp {
		t.Fatalf("unmatched lyric line should remain between neighbours: %+v", aligned)
	}
	if aligned[4].Timestamp <= aligned[3].Timestamp || aligned[4].Timestamp >= aligned[5].Timestamp {
		t.Fatalf("interlude line should be between lyric anchors: %+v", aligned)
	}

	leftGap := aligned[4].Timestamp - aligned[3].Timestamp
	rightGap := aligned[5].Timestamp - aligned[4].Timestamp
	if leftGap <= rightGap {
		t.Fatalf("interlude should be right-biased (leftGap=%f rightGap=%f): %+v", leftGap, rightGap, aligned)
	}
}
