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

func TestSanitiseTranscriptTextStripsZeroWidth(t *testing.T) {
	// カラオケ風字幕は装飾としてゼロ幅スペース (U+200B) を多用するため、
	// 歌詞テキストに残さず除去する必要がある。
	got := sanitiseTranscriptText("​ ​ ​Sera♦: Among all the stars​ ​")
	if got != "Sera♦: Among all the stars" {
		t.Fatalf("zero-width characters should be stripped: %q", got)
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

func TestParseTranscriptXMLBodyLegacyText(t *testing.T) {
	body := []byte(`<?xml version="1.0" encoding="utf-8"?>
<transcript>
  <text start="1.23" dur="1.5">Hello &amp; world</text>
  <text start="3.00" dur="2.0">Line two</text>
</transcript>`)

	transcript, formatName, err := parseTranscriptXMLBody(body)
	if err != nil {
		t.Fatalf("parseTranscriptXMLBody should succeed: %v", err)
	}
	if formatName != "xml-text" {
		t.Fatalf("unexpected format: %q", formatName)
	}
	if len(transcript) != 2 {
		t.Fatalf("segment length mismatch: got=%d want=2", len(transcript))
	}
	if transcript[0].StartMs != 1230 {
		t.Fatalf("unexpected first startMs: %d", transcript[0].StartMs)
	}
	if transcript[0].Text != "Hello & world" {
		t.Fatalf("unexpected first text: %q", transcript[0].Text)
	}
}

func TestParseTranscriptXMLBodyTimedTextFormat3(t *testing.T) {
	body := []byte(`<?xml version="1.0" encoding="utf-8"?>
<timedtext format="3">
  <body>
    <p t="22920" d="3100">I call your name</p>
    <p t="26020" d="3120"><s>Can you</s><s>hear me?</s></p>
  </body>
</timedtext>`)

	transcript, formatName, err := parseTranscriptXMLBody(body)
	if err != nil {
		t.Fatalf("parseTranscriptXMLBody should succeed: %v", err)
	}
	if formatName != "xml-timedtext-body" {
		t.Fatalf("unexpected format: %q", formatName)
	}
	if len(transcript) != 2 {
		t.Fatalf("segment length mismatch: got=%d want=2", len(transcript))
	}
	if transcript[0].StartMs != 22920 {
		t.Fatalf("unexpected first startMs: %d", transcript[0].StartMs)
	}
	if transcript[0].Text != "I call your name" {
		t.Fatalf("unexpected first text: %q", transcript[0].Text)
	}
	if transcript[1].Text != "Can you hear me?" {
		t.Fatalf("unexpected second text: %q", transcript[1].Text)
	}
}

// TestParseTranscriptXMLBodyDeduplicatesLayeredKaraoke は、カラオケ風に装飾された
// 字幕（同一開始時刻・同一テキストの <p> が縁取り用と塗り用の2層に分かれて重複する）を
// 1行に統合できることを検証する。再現元: youtube.com/watch?v=eghAYpSDtRw の en 字幕。
func TestParseTranscriptXMLBodyDeduplicatesLayeredKaraoke(t *testing.T) {
	body := []byte(`<?xml version="1.0" encoding="utf-8"?>
<timedtext format="3">
  <body>
    <p t="31081" d="2403"><s p="3">​ ​Sera♦: Among all the stars​ ​</s></p>
    <p t="31081" d="2403"><s p="5">​ ​Sera♦: Among all the stars​ ​</s></p>
    <p t="33484" d="3370"><s p="3">​ ​That shine in the sky​ ​</s></p>
    <p t="33484" d="3370"><s p="5">​ ​That shine in the sky​ ​</s></p>
  </body>
</timedtext>`)

	transcript, _, err := parseTranscriptXMLBody(body)
	if err != nil {
		t.Fatalf("parseTranscriptXMLBody should succeed: %v", err)
	}
	if len(transcript) != 2 {
		t.Fatalf("layered karaoke should be deduplicated to 2 lines: got=%d", len(transcript))
	}
	if transcript[0].StartMs != 31081 || transcript[1].StartMs != 33484 {
		t.Fatalf("unexpected startMs: %d, %d", transcript[0].StartMs, transcript[1].StartMs)
	}
}
