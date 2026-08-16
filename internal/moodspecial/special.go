// Package moodspecial builds mood-themed playlist features by sending a list of
// candidate tracks to a chat LLM and parsing the structured response.
//
// The LLM never sees raw file paths — candidates are referenced by 1-based
// indices in the prompt, and indices are mapped back to TrackIDs after
// parsing. This protects against the LLM hallucinating or mistyping paths.
package moodspecial

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// Candidate is one track the LLM may include in the generated feature.
type Candidate struct {
	TrackID string
	Title   string
	Artist  string
	Album   string
}

// Feature is the final, materialised playlist feature returned to callers.
type Feature struct {
	Title            string            `json:"title"`
	Description      string            `json:"description"`
	OrderedTrackIDs  []string          `json:"orderedTrackIds"`
	PerTrackComments map[string]string `json:"perTrackComments"`
}

// ChatOpts is the minimal knob set passed through to the LLM client.
type ChatOpts struct {
	NPredict int
	Temp     float64
}

// LLMChat decouples this package from any concrete LLM client.
// llamasrv.Client satisfies it via a small adapter (see app_special.go).
type LLMChat interface {
	Chat(ctx context.Context, userMessage string, opts ChatOpts) (string, error)
}

// BuildPrompt formats the user-side message sent to the LLM.
func BuildPrompt(mood string, candidates []Candidate) string {
	var b strings.Builder
	b.WriteString("あなたは音楽キュレーターです。次のテーマに合う特集プレイリストを編成してください。\n\n")
	b.WriteString("テーマ: ")
	b.WriteString(mood)
	b.WriteString("\n\n候補曲 (候補リストにある曲のみを使用してください):\n")
	for i, c := range candidates {
		fmt.Fprintf(&b, "[%d] %s / %s", i+1, fallback(c.Title, "(無題)"), fallback(c.Artist, "(不明)"))
		if c.Album != "" {
			fmt.Fprintf(&b, " — アルバム: %s", c.Album)
		}
		b.WriteString("\n")
	}
	b.WriteString(`
以下の JSON のみで回答してください (前置きや解説は不要):

{
  "title": "特集タイトル (30文字以内)",
  "description": "200字程度の紹介文を1段落で",
  "ordered_track_refs": [候補の番号を盛り上がりカーブが綺麗な順に並べた配列],
  "per_track_comments": {"番号": "30〜50字のコメント"}
}

制約:
- ordered_track_refs は候補番号 (1 以上 ` + strconv.Itoa(len(candidates)) + ` 以下) のみを使用
- リスト外の曲名・アーティスト名は絶対に作らないこと
- 候補曲は ` + strconv.Itoa(maxFeatureSize(len(candidates))) + ` 曲以内で取捨選択して良い
`)
	return b.String()
}

// llmJSON mirrors the JSON contract the prompt asks for.
type llmJSON struct {
	Title            string            `json:"title"`
	Description      string            `json:"description"`
	OrderedRefs      []int             `json:"ordered_track_refs"`
	PerTrackComments map[string]string `json:"per_track_comments"`
}

// ParseLLMResponse pulls the first JSON object out of raw LLM text and decodes
// it. The LLM frequently wraps JSON in prose; we scan for the matching braces.
func ParseLLMResponse(raw string) (llmJSON, error) {
	start := strings.Index(raw, "{")
	if start < 0 {
		return llmJSON{}, fmt.Errorf("special: no JSON object in response")
	}
	// Find the matching closing brace via depth counting (handles nested objects).
	depth := 0
	end := -1
	inString := false
	escape := false
	for i := start; i < len(raw); i++ {
		ch := raw[i]
		if escape {
			escape = false
			continue
		}
		if ch == '\\' {
			escape = true
			continue
		}
		if ch == '"' {
			inString = !inString
			continue
		}
		if inString {
			continue
		}
		switch ch {
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				end = i
			}
		}
		if end >= 0 {
			break
		}
	}
	if end < 0 {
		return llmJSON{}, fmt.Errorf("special: unbalanced JSON in response")
	}
	body := raw[start : end+1]
	var out llmJSON
	if err := json.Unmarshal([]byte(body), &out); err != nil {
		return llmJSON{}, fmt.Errorf("special: parse JSON: %w (body=%q)", err, truncate(body, 200))
	}
	return out, nil
}

// Materialise maps a parsed LLM response back onto real track IDs.
// Invalid refs (out of range, duplicate) are silently dropped.
func Materialise(parsed llmJSON, candidates []Candidate) Feature {
	feat := Feature{
		Title:            strings.TrimSpace(parsed.Title),
		Description:      strings.TrimSpace(parsed.Description),
		PerTrackComments: map[string]string{},
	}
	seen := map[int]bool{}
	for _, ref := range parsed.OrderedRefs {
		if ref < 1 || ref > len(candidates) || seen[ref] {
			continue
		}
		seen[ref] = true
		feat.OrderedTrackIDs = append(feat.OrderedTrackIDs, candidates[ref-1].TrackID)
	}
	for refStr, comment := range parsed.PerTrackComments {
		ref, err := strconv.Atoi(refStr)
		if err != nil || ref < 1 || ref > len(candidates) {
			continue
		}
		feat.PerTrackComments[candidates[ref-1].TrackID] = strings.TrimSpace(comment)
	}
	return feat
}

// Generate runs the full prompt → LLM → parse → materialise flow.
func Generate(ctx context.Context, mood string, candidates []Candidate, llm LLMChat) (Feature, error) {
	if strings.TrimSpace(mood) == "" {
		return Feature{}, fmt.Errorf("special: empty mood")
	}
	if len(candidates) == 0 {
		return Feature{}, fmt.Errorf("special: no candidates")
	}
	prompt := BuildPrompt(mood, candidates)
	raw, err := llm.Chat(ctx, prompt, ChatOpts{NPredict: 800, Temp: 0.7})
	if err != nil {
		return Feature{}, fmt.Errorf("special: LLM chat: %w", err)
	}
	parsed, err := ParseLLMResponse(raw)
	if err != nil {
		return Feature{}, err
	}
	return Materialise(parsed, candidates), nil
}

func maxFeatureSize(candidateCount int) int {
	if candidateCount < 10 {
		return candidateCount
	}
	return 10
}

func fallback(s, def string) string {
	if strings.TrimSpace(s) == "" {
		return def
	}
	return s
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "…"
}
