package lyricssync

import "testing"

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
