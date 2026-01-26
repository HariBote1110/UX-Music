package normalize

// AnalysisResult holds the result of loudness analysis
type AnalysisResult struct {
	Success  bool    `json:"success"`
	Loudness float64 `json:"loudness"` // mean_volume
	TruePeak float64 `json:"truePeak"` // max_volume
	Error    string  `json:"error,omitempty"`
}

// OutputSettings configuration for output files
type OutputSettings struct {
	Mode string `json:"mode"` // "overwrite" or "separate"
	Path string `json:"path"` // Output directory if separate
}

// NormalizeJob represents a normalization task
type NormalizeJob struct {
	ID       string         `json:"id"`
	FilePath string         `json:"filePath"`
	Gain     float64        `json:"gain"`
	Backup   bool           `json:"backup"`
	Output   OutputSettings `json:"output"`
	BasePath string         `json:"basePath"` // For relative path calculation
}

// NormalizeResult result of normalization
type NormalizeResult struct {
	Success    bool   `json:"success"`
	OutputPath string `json:"outputPath"`
	Error      string `json:"error,omitempty"`
}
