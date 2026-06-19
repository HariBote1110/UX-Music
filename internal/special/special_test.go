package special

import (
	"context"
	"strings"
	"testing"
)

func sampleCandidates() []Candidate {
	return []Candidate{
		{TrackID: "/a.mp3", Title: "Nighthawk", Artist: "Yui", Album: "Drive"},
		{TrackID: "/b.mp3", Title: "Highway Star", Artist: "Capsule", Album: "Cruise"},
		{TrackID: "/c.mp3", Title: "Slow Pulse", Artist: "Perfume", Album: "City"},
	}
}

func TestBuildPrompt_ContainsMoodAndIndexedCandidates(t *testing.T) {
	p := BuildPrompt("夜のドライブ", sampleCandidates())
	if !strings.Contains(p, "夜のドライブ") {
		t.Error("mood missing from prompt")
	}
	for _, ref := range []string{"[1]", "[2]", "[3]"} {
		if !strings.Contains(p, ref) {
			t.Errorf("index ref %q missing", ref)
		}
	}
	if !strings.Contains(p, "Nighthawk") || !strings.Contains(p, "Capsule") {
		t.Error("candidate metadata missing")
	}
	if !strings.Contains(p, "ordered_track_refs") {
		t.Error("schema hint missing")
	}
	// Paths must NOT be in the prompt (they're easy to misquote).
	if strings.Contains(p, "/a.mp3") {
		t.Error("raw path leaked into prompt")
	}
}

func TestParseLLMResponse_ExtractsJSONFromNoise(t *testing.T) {
	raw := `ここに特集を提案します。

{
  "title": "深夜のハイウェイ",
  "description": "都会の喧騒を抜けて、夜のハイウェイを駆け抜けるための10曲。",
  "ordered_track_refs": [2, 1, 3],
  "per_track_comments": {
    "2": "疾走感のオープナー",
    "1": "クールダウン",
    "3": "余韻"
  }
}

以上です。`
	parsed, err := ParseLLMResponse(raw)
	if err != nil {
		t.Fatalf("ParseLLMResponse: %v", err)
	}
	if parsed.Title != "深夜のハイウェイ" {
		t.Errorf("title: %q", parsed.Title)
	}
	if len(parsed.OrderedRefs) != 3 || parsed.OrderedRefs[0] != 2 {
		t.Errorf("ordered_refs: %v", parsed.OrderedRefs)
	}
	if parsed.PerTrackComments["1"] != "クールダウン" {
		t.Errorf("comments: %v", parsed.PerTrackComments)
	}
}

func TestParseLLMResponse_RejectsMissingJSON(t *testing.T) {
	if _, err := ParseLLMResponse("ただの文章で JSON は無いです。"); err == nil {
		t.Fatal("expected error for missing JSON")
	}
}

func TestMaterialise_MapsRefsToTrackIDsAndSkipsOutOfRange(t *testing.T) {
	cands := sampleCandidates()
	parsed := llmJSON{
		Title:       "テスト特集",
		Description: "説明",
		OrderedRefs: []int{2, 99, 1, 0}, // 99 and 0 are invalid
		PerTrackComments: map[string]string{
			"2":   "two",
			"1":   "one",
			"99":  "should-be-dropped",
			"abc": "noise",
		},
	}
	feat := Materialise(parsed, cands)
	// Valid refs (1..3) mapped to TrackIDs of cands[ref-1].
	if got := feat.OrderedTrackIDs; len(got) != 2 || got[0] != "/b.mp3" || got[1] != "/a.mp3" {
		t.Errorf("ordered: %v", got)
	}
	if feat.PerTrackComments["/b.mp3"] != "two" {
		t.Errorf("missing /b comment: %v", feat.PerTrackComments)
	}
	if feat.PerTrackComments["/a.mp3"] != "one" {
		t.Errorf("missing /a comment: %v", feat.PerTrackComments)
	}
	if _, ok := feat.PerTrackComments["should-be-dropped"]; ok {
		t.Error("invalid comment should be dropped")
	}
}

type stubLLM struct{ reply string }

func (s stubLLM) Chat(_ context.Context, _ string, _ ChatOpts) (string, error) {
	return s.reply, nil
}

func TestGenerate_EndToEndWithStubLLM(t *testing.T) {
	llm := stubLLM{reply: `{
        "title": "夜ドライブ特集",
        "description": "夜の高速道路にぴったり。",
        "ordered_track_refs": [1, 3],
        "per_track_comments": {"1": "幕開け", "3": "余韻"}
    }`}
	feat, err := Generate(context.Background(), "夜のドライブ", sampleCandidates(), llm)
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if feat.Title != "夜ドライブ特集" {
		t.Errorf("title: %q", feat.Title)
	}
	if len(feat.OrderedTrackIDs) != 2 {
		t.Errorf("expected 2 tracks, got %d", len(feat.OrderedTrackIDs))
	}
	if feat.OrderedTrackIDs[0] != "/a.mp3" {
		t.Errorf("first track: %q", feat.OrderedTrackIDs[0])
	}
}
