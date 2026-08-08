package youtube

import (
	"math"
	"testing"
)

// 実測（2026-07-13、innertube ANDROID クライアント）:
//   dQw4w9WgXcQ: loudnessDb=0.9899998, perceptualLoudnessDb=-13.01
//   9bZkp7q19f0: loudnessDb=6.69,      perceptualLoudnessDb=-7.31
//     → 同動画の音声を ffmpeg ebur128 で解析した統合ラウドネスは -7.3 LUFS
// いずれも perceptualLoudnessDb = -14 + loudnessDb が成立し、
// perceptualLoudnessDb がコンテンツの実効ラウドネス（LUFS）に一致する。

func floatPtr(v float64) *float64 { return &v }

func TestParseEmbedLoudness(t *testing.T) {
	t.Run("both fields present", func(t *testing.T) {
		body := []byte(`{"playerConfig":{"audioConfig":{"loudnessDb":6.69,"perceptualLoudnessDb":-7.31,"enablePerFormatLoudness":true}}}`)
		got := parseEmbedLoudness(body)
		if got.LoudnessDb == nil || math.Abs(*got.LoudnessDb-6.69) > 1e-9 {
			t.Fatalf("LoudnessDb = %v, want 6.69", got.LoudnessDb)
		}
		if got.PerceptualLoudnessDb == nil || math.Abs(*got.PerceptualLoudnessDb-(-7.31)) > 1e-9 {
			t.Fatalf("PerceptualLoudnessDb = %v, want -7.31", got.PerceptualLoudnessDb)
		}
	})

	t.Run("loudnessDb only", func(t *testing.T) {
		body := []byte(`{"playerConfig":{"audioConfig":{"loudnessDb":-2.5}}}`)
		got := parseEmbedLoudness(body)
		if got.LoudnessDb == nil || math.Abs(*got.LoudnessDb-(-2.5)) > 1e-9 {
			t.Fatalf("LoudnessDb = %v, want -2.5", got.LoudnessDb)
		}
		if got.PerceptualLoudnessDb != nil {
			t.Fatalf("PerceptualLoudnessDb = %v, want nil", got.PerceptualLoudnessDb)
		}
	})

	t.Run("absent audioConfig", func(t *testing.T) {
		body := []byte(`{"playerConfig":{}}`)
		got := parseEmbedLoudness(body)
		if got.LoudnessDb != nil || got.PerceptualLoudnessDb != nil {
			t.Fatalf("expected empty loudness, got %+v", got)
		}
	})

	t.Run("invalid json", func(t *testing.T) {
		got := parseEmbedLoudness([]byte(`not json`))
		if got.LoudnessDb != nil || got.PerceptualLoudnessDb != nil {
			t.Fatalf("expected empty loudness, got %+v", got)
		}
	})
}

func TestEffectiveLoudnessLUFS(t *testing.T) {
	t.Run("prefers perceptualLoudnessDb", func(t *testing.T) {
		l := EmbedLoudness{LoudnessDb: floatPtr(6.69), PerceptualLoudnessDb: floatPtr(-7.31)}
		got, ok := EffectiveLoudnessLUFS(l)
		if !ok || math.Abs(got-(-7.31)) > 1e-9 {
			t.Fatalf("got %v ok=%v, want -7.31 true", got, ok)
		}
	})

	t.Run("derives from loudnessDb via -14 reference", func(t *testing.T) {
		l := EmbedLoudness{LoudnessDb: floatPtr(0.99)}
		got, ok := EffectiveLoudnessLUFS(l)
		if !ok || math.Abs(got-(-13.01)) > 1e-9 {
			t.Fatalf("got %v ok=%v, want -13.01 true", got, ok)
		}
	})

	t.Run("unavailable when neither field present", func(t *testing.T) {
		if _, ok := EffectiveLoudnessLUFS(EmbedLoudness{}); ok {
			t.Fatal("expected ok=false")
		}
	})

	t.Run("rejects non-finite values", func(t *testing.T) {
		l := EmbedLoudness{PerceptualLoudnessDb: floatPtr(math.NaN()), LoudnessDb: floatPtr(math.Inf(1))}
		if _, ok := EffectiveLoudnessLUFS(l); ok {
			t.Fatal("expected ok=false for non-finite values")
		}
	})
}
