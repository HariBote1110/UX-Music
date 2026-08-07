package audio

import (
	"math"
	"testing"
)

// newTestFFTPlayer creates a Player with FFT buffers initialised, without
// touching PortAudio hardware (matches the pattern used by other *_test.go
// files in this package that construct &Player{} directly).
func newTestFFTPlayer(t *testing.T) *Player {
	t.Helper()
	p := &Player{}
	p.initFFT(2048)
	return p
}

// generateSine builds a sine wave of the given amplitude and frequency,
// sampled at sampleRate, with the given number of samples.
func generateSine(amplitude, freq, sampleRate float64, n int) []float64 {
	out := make([]float64, n)
	for i := 0; i < n; i++ {
		out[i] = amplitude * math.Sin(2*math.Pi*freq*float64(i)/sampleRate)
	}
	return out
}

func TestCalculateFFT_SineHasContrastAndIsNotClamped(t *testing.T) {
	p := newTestFFTPlayer(t)

	const sampleRate = 44100.0
	const n = 2048
	// Pick a bin-centre frequency: bin k corresponds to k*sampleRate/n.
	const bin = 100
	freq := float64(bin) * sampleRate / n

	input := generateSine(0.5, freq, sampleRate, n)
	p.calculateFFT(input)

	data := p.GetFrequencyData()
	if len(data) == 0 {
		t.Fatalf("expected non-empty frequency data")
	}

	peak := data[bin]
	if peak >= 255 {
		t.Fatalf("peak bin pegged at max (255); expected well below 255 (unnormalised FFT bug), got %d", peak)
	}
	if peak < 100 {
		t.Fatalf("peak bin unexpectedly low: got %d, expected between 100 and 254", peak)
	}

	// A bin far from the peak should be much lower (spectrum should have contrast).
	farBin := bin + 400
	if farBin >= len(data) {
		farBin = len(data) - 1
	}
	if data[farBin] >= peak {
		t.Fatalf("expected far bin (%d) to be much lower than peak bin (%d), got far=%d peak=%d", farBin, bin, data[farBin], peak)
	}
}

func TestCalculateFFT_SilenceProducesAllZero(t *testing.T) {
	p := newTestFFTPlayer(t)

	input := make([]float64, p.fftSize) // all zeros
	p.calculateFFT(input)

	data := p.GetFrequencyData()
	for i, v := range data {
		if v != 0 {
			t.Fatalf("expected all bins to be 0 for silence, bin %d = %d", i, v)
		}
	}
}

func TestCalculateFFT_TemporalSmoothingDecaysRatherThanDropsInstantly(t *testing.T) {
	p := newTestFFTPlayer(t)

	const sampleRate = 44100.0
	const n = 2048
	const bin = 100
	freq := float64(bin) * sampleRate / n

	loud := generateSine(0.5, freq, sampleRate, n)
	p.calculateFFT(loud)
	loudData := p.GetFrequencyData()
	loudPeak := loudData[bin]

	silent := make([]float64, n)
	p.calculateFFT(silent)
	silentData := p.GetFrequencyData()
	silentPeak := silentData[bin]

	if silentPeak == 0 {
		t.Fatalf("expected smoothed decay (>0) after one silent frame following a loud frame, got 0")
	}
	if silentPeak >= loudPeak {
		t.Fatalf("expected silent-frame peak (%d) to be lower than loud-frame peak (%d)", silentPeak, loudPeak)
	}
}
