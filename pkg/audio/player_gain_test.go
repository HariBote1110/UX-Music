package audio

import (
	"math"
	"testing"
)

func TestSanitizePlaybackGainLinear(t *testing.T) {
	t.Parallel()
	if g := sanitizePlaybackGainLinear(0.5); g != 0.5 {
		t.Errorf("valid mid gain: got %g, want 0.5", g)
	}
	if g := sanitizePlaybackGainLinear(1.0); g != 1.0 {
		t.Errorf("unity: got %g, want 1.0", g)
	}
	if g := sanitizePlaybackGainLinear(0); g != 1.0 {
		t.Errorf("zero: got %g, want 1.0", g)
	}
	if g := sanitizePlaybackGainLinear(-1); g != 1.0 {
		t.Errorf("negative: got %g, want 1.0", g)
	}
	if g := sanitizePlaybackGainLinear(math.NaN()); g != 1.0 {
		t.Errorf("NaN: got %g, want 1.0", g)
	}
	if g := sanitizePlaybackGainLinear(math.Inf(1)); g != 1.0 {
		t.Errorf("+Inf: got %g, want 1.0", g)
	}
}
