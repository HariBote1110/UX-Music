package audio

import (
	"math"
	"math/cmplx"
	"testing"
)

// biquadMagnitudeAt は係数 coeff の周波数 freq における振幅応答を返す。
// テストが期待値をハードコードせずに済むよう、伝達関数から直接求める。
func biquadMagnitudeAt(coeff biquadCoefficients, freq float64, sampleRate int) float64 {
	w := 2 * math.Pi * freq / float64(sampleRate)
	z := cmplx.Exp(complex(0, -w))
	num := complex(coeff.b0, 0) + complex(coeff.b1, 0)*z + complex(coeff.b2, 0)*z*z
	den := complex(1, 0) + complex(coeff.a1, 0)*z + complex(coeff.a2, 0)*z*z
	return cmplx.Abs(num / den)
}

func TestKWeightingCoefficientsMatchBS1770At48k(t *testing.T) {
	t.Parallel()
	stage1, stage2 := kWeightingCoefficients(48000)

	// ITU-R BS.1770-4 表 1（48 kHz、a0 で正規化済み）。
	wantStage1 := biquadCoefficients{
		b0: 1.53512485958697,
		b1: -2.69169618940638,
		b2: 1.19839281085285,
		a1: -1.69065929318241,
		a2: 0.73248077421585,
	}
	// 表 2（RLB ハイパス）。
	wantStage2 := biquadCoefficients{
		b0: 1.0,
		b1: -2.0,
		b2: 1.0,
		a1: -1.99004745483398,
		a2: 0.99007225036621,
	}

	const tolerance = 1e-6
	checkCoefficients := func(label string, got, want biquadCoefficients) {
		t.Helper()
		pairs := []struct {
			name      string
			got, want float64
		}{
			{"b0", got.b0, want.b0},
			{"b1", got.b1, want.b1},
			{"b2", got.b2, want.b2},
			{"a1", got.a1, want.a1},
			{"a2", got.a2, want.a2},
		}
		for _, p := range pairs {
			if math.Abs(p.got-p.want) > tolerance {
				t.Errorf("%s.%s: got %.14f, want %.14f", label, p.name, p.got, p.want)
			}
		}
	}
	checkCoefficients("stage1", stage1, wantStage1)
	checkCoefficients("stage2", stage2, wantStage2)
}

func TestKWeightingCoefficientsAdaptToSampleRate(t *testing.T) {
	t.Parallel()
	// 44.1 kHz でも 48 kHz と同じ周波数特性（1 kHz と 10 kHz の相対利得）になること。
	s1At48, s2At48 := kWeightingCoefficients(48000)
	s1At441, s2At441 := kWeightingCoefficients(44100)

	gain := func(s1, s2 biquadCoefficients, freq float64, rate int) float64 {
		return 20 * math.Log10(biquadMagnitudeAt(s1, freq, rate)*biquadMagnitudeAt(s2, freq, rate))
	}
	for _, freq := range []float64{100, 1000, 10000} {
		got48 := gain(s1At48, s2At48, freq, 48000)
		got441 := gain(s1At441, s2At441, freq, 44100)
		if math.Abs(got48-got441) > 0.15 {
			t.Errorf("%.0fHz: 48k=%.3fdB, 44.1k=%.3fdB (差が大きすぎる)", freq, got48, got441)
		}
	}
}

func TestBlockMeanSquaresFromSubBlocksUsesOverlappingWindows(t *testing.T) {
	t.Parallel()
	// 100ms サブブロック 6 個 → 400ms ブロックが 75% オーバーラップで 3 個。
	sub := []float64{1, 2, 3, 4, 5, 6}
	got := blockMeanSquaresFromSubBlocks(sub)
	want := []float64{
		(1 + 2 + 3 + 4) / 4.0,
		(2 + 3 + 4 + 5) / 4.0,
		(3 + 4 + 5 + 6) / 4.0,
	}
	if len(got) != len(want) {
		t.Fatalf("ブロック数: got %d, want %d", len(got), len(want))
	}
	for i := range want {
		if math.Abs(got[i]-want[i]) > 1e-12 {
			t.Errorf("block[%d]: got %g, want %g", i, got[i], want[i])
		}
	}
}

func TestBlockMeanSquaresFromSubBlocksNeedsFullWindow(t *testing.T) {
	t.Parallel()
	if got := blockMeanSquaresFromSubBlocks([]float64{1, 2, 3}); len(got) != 0 {
		t.Fatalf("400ms 未満では空を返すべき: got %v", got)
	}
}

func TestIntegratedLoudnessFromBlocksAppliesAbsoluteGate(t *testing.T) {
	t.Parallel()
	// -23 LUFS 相当のブロックと、絶対ゲート（-70 LUFS）以下の無音ブロック。
	loud := math.Pow(10, (-23+0.691)/10)
	blocks := []float64{loud, loud, 1e-12, 0, loud}

	got, ok := integratedLoudnessFromBlocks(blocks)
	if !ok {
		t.Fatal("有効なブロックがあるのに ok=false")
	}
	if math.Abs(got-(-23)) > 0.01 {
		t.Fatalf("無音が混ざっても -23 LUFS のはず: got %.3f", got)
	}
}

func TestIntegratedLoudnessFromBlocksAppliesRelativeGate(t *testing.T) {
	t.Parallel()
	// 大きい部分 -20 LUFS が 4 ブロック、小さい部分 -45 LUFS が 4 ブロック。
	// 相対ゲート（-10 LU）により小さい部分は除外され、結果は -20 LUFS に近づく。
	loud := math.Pow(10, (-20+0.691)/10)
	quiet := math.Pow(10, (-45+0.691)/10)
	blocks := []float64{loud, loud, loud, loud, quiet, quiet, quiet, quiet}

	got, ok := integratedLoudnessFromBlocks(blocks)
	if !ok {
		t.Fatal("ok=false")
	}
	if math.Abs(got-(-20)) > 0.05 {
		t.Fatalf("相対ゲートで静かな部分が除外されるはず: got %.3f, want ≈ -20", got)
	}
}

func TestIntegratedLoudnessFromBlocksReportsUnavailable(t *testing.T) {
	t.Parallel()
	if _, ok := integratedLoudnessFromBlocks(nil); ok {
		t.Fatal("ブロックなしで ok=true")
	}
	if _, ok := integratedLoudnessFromBlocks([]float64{0, 0, 0}); ok {
		t.Fatal("全て無音なら ok=false であるべき")
	}
}

// feedSine は meter へ振幅 amp の 1 kHz 正弦波を seconds 秒ぶん流し込む。
func feedSine(meter *loudnessMeter, amp float64, seconds float64, sampleRate, channels int) {
	frames := int(float64(sampleRate) * seconds)
	for i := 0; i < frames; i++ {
		v := amp * math.Sin(2*math.Pi*1000*float64(i)/float64(sampleRate))
		for ch := 0; ch < channels; ch++ {
			meter.processSample(ch, v)
		}
	}
}

func TestLoudnessMeterMeasuresSteadySine(t *testing.T) {
	t.Parallel()
	const sampleRate = 48000
	const channels = 2
	const amp = 0.5

	meter := newLoudnessMeter(sampleRate, channels)
	feedSine(meter, amp, 3.0, sampleRate, channels)

	got, ok := meter.integratedLUFS()
	if !ok {
		t.Fatal("3 秒ぶん流したのに測定できていない")
	}

	// 期待値: z = Σ_ch (amp^2 / 2) * |H(1kHz)|^2、LUFS = -0.691 + 10log10(z)
	stage1, stage2 := kWeightingCoefficients(sampleRate)
	h := biquadMagnitudeAt(stage1, 1000, sampleRate) * biquadMagnitudeAt(stage2, 1000, sampleRate)
	z := float64(channels) * (amp * amp / 2) * h * h
	want := -0.691 + 10*math.Log10(z)

	if math.Abs(got-want) > 0.2 {
		t.Fatalf("測定値: got %.3f LUFS, want %.3f LUFS", got, want)
	}
}

func TestLoudnessMeterIsLinearInAmplitude(t *testing.T) {
	t.Parallel()
	const sampleRate = 48000
	const channels = 2

	quiet := newLoudnessMeter(sampleRate, channels)
	feedSine(quiet, 0.1, 2.0, sampleRate, channels)
	loud := newLoudnessMeter(sampleRate, channels)
	feedSine(loud, 0.2, 2.0, sampleRate, channels)

	quietLUFS, ok1 := quiet.integratedLUFS()
	loudLUFS, ok2 := loud.integratedLUFS()
	if !ok1 || !ok2 {
		t.Fatal("測定できていない")
	}
	if diff := loudLUFS - quietLUFS; math.Abs(diff-6.02) > 0.1 {
		t.Fatalf("振幅 2 倍は +6.02 dB のはず: got %.3f dB", diff)
	}
}

func TestLoudnessMeterNeedsEnoughAudio(t *testing.T) {
	t.Parallel()
	meter := newLoudnessMeter(48000, 2)
	feedSine(meter, 0.5, 0.2, 48000, 2) // 400ms 未満
	if _, ok := meter.integratedLUFS(); ok {
		t.Fatal("400ms 未満で測定値を返してはいけない")
	}
}

func TestLoudnessMeterIgnoresSilence(t *testing.T) {
	t.Parallel()
	const sampleRate = 48000
	const channels = 2
	meter := newLoudnessMeter(sampleRate, channels)

	// 先頭 2 秒は無音（再生開始直後のプリロール相当）、その後 2 秒だけ信号。
	for i := 0; i < sampleRate*2; i++ {
		for ch := 0; ch < channels; ch++ {
			meter.processSample(ch, 0)
		}
	}
	feedSine(meter, 0.5, 2.0, sampleRate, channels)

	withSilence, ok := meter.integratedLUFS()
	if !ok {
		t.Fatal("測定できていない")
	}

	reference := newLoudnessMeter(sampleRate, channels)
	feedSine(reference, 0.5, 2.0, sampleRate, channels)
	want, _ := reference.integratedLUFS()

	if math.Abs(withSilence-want) > 0.3 {
		t.Fatalf("無音は絶対ゲートで除外されるはず: got %.3f, want ≈ %.3f", withSilence, want)
	}
}

func TestResolveLiveCorrectionGain(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name       string
		measured   float64
		target     float64
		applied    float64
		wantFactor float64
	}{
		{
			// 素の音が -14 LUFS、目標 -18、すでに -4 dB 掛かっている → 補正不要。
			name:       "推定が正しければ補正なし",
			measured:   -14,
			target:     -18,
			applied:    math.Pow(10, -4.0/20),
			wantFactor: 1.0,
		},
		{
			// 二重減衰の再現: 素の音は -14 だが -10.69 dB 掛けてしまっている。
			// 必要な総ゲインは -4 dB なので、+6.69 dB ぶん戻す。
			name:       "掛けすぎたぶんを戻す",
			measured:   -14,
			target:     -18,
			applied:    math.Pow(10, -10.69/20),
			wantFactor: math.Pow(10, 6.69/20),
		},
		{
			name:       "補正量は +12 dB で頭打ち",
			measured:   -60,
			target:     -18,
			applied:    1.0,
			wantFactor: math.Pow(10, 12.0/20),
		},
		{
			name:       "補正量は -12 dB で頭打ち",
			measured:   0,
			target:     -40,
			applied:    1.0,
			wantFactor: math.Pow(10, -12.0/20),
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := resolveLiveCorrectionGain(tc.measured, tc.target, tc.applied)
			if math.Abs(got-tc.wantFactor) > 1e-6 {
				t.Fatalf("got %.6f, want %.6f", got, tc.wantFactor)
			}
		})
	}
}

func TestResolveLiveCorrectionGainRejectsInvalidInput(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name                       string
		measured, target, appliedG float64
	}{
		{"measured が NaN", math.NaN(), -18, 1},
		{"target が Inf", -14, math.Inf(1), 1},
		{"適用ゲインが 0", -14, -18, 0},
		{"適用ゲインが負", -14, -18, -1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := resolveLiveCorrectionGain(tc.measured, tc.target, tc.appliedG); got != 1.0 {
				t.Fatalf("不正入力では 1.0 を返すべき: got %v", got)
			}
		})
	}
}
