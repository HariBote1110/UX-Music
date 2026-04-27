package audio

import "math"

// sanitizePlaybackGainLinear returns 1.0 for invalid or non-positive values (Wails loudness path).
func sanitizePlaybackGainLinear(gainLinear float64) float64 {
	if gainLinear <= 0 || math.IsNaN(gainLinear) || math.IsInf(gainLinear, 0) {
		return 1.0
	}
	return gainLinear
}
