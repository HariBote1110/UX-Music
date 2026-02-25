package youtube

import (
	"strings"
	"testing"

	yt "github.com/kkdai/youtube/v2"
)

func TestBuildCaptionTrackCandidatesPriority(t *testing.T) {
	tracks := []yt.CaptionTrack{
		{LanguageCode: "en", Kind: "asr"},
		{LanguageCode: "fr"},
		{LanguageCode: "ja"},
		{LanguageCode: "en"},
		{LanguageCode: "ja", Kind: "asr"},
	}

	candidates := buildCaptionTrackCandidates(tracks)
	if len(candidates) != len(tracks) {
		t.Fatalf("candidate length mismatch: got=%d want=%d", len(candidates), len(tracks))
	}

	if candidates[0].Track.LanguageCode != "ja" || isAutoCaption(candidates[0].Track) {
		t.Fatalf("first priority should be manual ja track: %+v", candidates[0].Track)
	}

	if candidates[1].Track.LanguageCode != "en" || isAutoCaption(candidates[1].Track) {
		t.Fatalf("second priority should be manual en track: %+v", candidates[1].Track)
	}

	if !isAutoCaption(candidates[len(candidates)-1].Track) {
		t.Fatalf("last priority should be auto caption track: %+v", candidates[len(candidates)-1].Track)
	}
}

func TestTranscriptToLRC(t *testing.T) {
	video := &yt.Video{
		Title:  "Test Song",
		Author: "Test Artist",
	}
	transcript := yt.VideoTranscript{
		{Text: "Hello  world", StartMs: 1234},
		{Text: " ", StartMs: 5000},
		{Text: "Line\nBreak", StartMs: 65000},
	}

	lrc := transcriptToLRC(video, transcript)
	if !strings.HasPrefix(lrc, "[ti:Test Song]\n[ar:Test Artist]\n") {
		t.Fatalf("metadata lines missing: %q", lrc)
	}

	if !strings.Contains(lrc, "[00:01.23]Hello world") {
		t.Fatalf("first lyric line mismatch: %q", lrc)
	}

	if !strings.Contains(lrc, "[01:05.00]Line Break") {
		t.Fatalf("second lyric line mismatch: %q", lrc)
	}
}
