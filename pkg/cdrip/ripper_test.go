package cdrip

import (
	"testing"
)

func TestSanitize(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"Hello World", "Hello World"},
		{"AC/DC", "AC_DC"},
		{"What?", "What_"},
		{"<Invalid>", "_Invalid_"},
	}

	for _, test := range tests {
		got := sanitize(test.input)
		if got != test.expected {
			t.Errorf("sanitize(%q) = %q; want %q", test.input, got, test.expected)
		}
	}
}

func TestParseTrackList(t *testing.T) {
	output := `
Ripping from sector       0 (track  1 [0:00.00])
          to sector   19213 (track  1 [4:16.13])

outputting to rip_123_track1.wav

 (== PROGRESS == [                              | 000275 00 ] == :^D * ==)   
									
  1. 19214
  2. 15432
  3. 20000
`
	tracks := parseTrackList(output)
	if len(tracks) != 3 {
		t.Errorf("Expected 3 tracks, got %d", len(tracks))
	}
	if len(tracks) > 0 {
		if tracks[0].Number != 1 || tracks[0].Sectors != 19214 {
			t.Errorf("Track 1 mismatch: %+v", tracks[0])
		}
	}
}
