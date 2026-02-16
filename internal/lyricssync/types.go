package lyricssync

type Request struct {
	SongPath string   `json:"songPath"`
	Lines    []string `json:"lines"`
	Language string   `json:"language"` // "auto-ja"
	Profile  string   `json:"profile"`  // "fast"
}

type AlignedLine struct {
	Index      int     `json:"index"`
	Text       string  `json:"text"`
	Timestamp  float64 `json:"timestamp"`
	Confidence float64 `json:"confidence"`
	Source     string  `json:"source"` // "match" | "interpolated" | "interlude"
}

type DetectedSegment struct {
	Start float64 `json:"start"`
	End   float64 `json:"end"`
	Text  string  `json:"text"`
}

type Result struct {
	Success          bool              `json:"success"`
	Lines            []AlignedLine     `json:"lines,omitempty"`
	MatchedCount     int               `json:"matchedCount,omitempty"`
	DetectedBy       string            `json:"detectedBy,omitempty"`
	DetectedSegments []DetectedSegment `json:"detectedSegments,omitempty"`
	Error            string            `json:"error,omitempty"`
}

type whisperSegment struct {
	Start float64
	End   float64
	Text  string
}
