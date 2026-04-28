package lyricssync

type Request struct {
	SongPath string `json:"songPath"`
	Lines    []string `json:"lines"`
	Language string `json:"language"` // "auto", "ja", "en"
	Profile  string `json:"profile"`  // legacy; forwarded to Python

	AllowModelDownload bool   `json:"allowModelDownload,omitempty"`
	WhisperModel       string `json:"whisperModel,omitempty"` // "small" | "medium" | "large-v3-turbo"; default medium in Python
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
