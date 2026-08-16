package audio

import (
	"math"
	"testing"
	"time"
)

// pumpLive は samples をライブソースへ流し込み、リングへ届いたぶんを
// processAudio で消費する（= オーディオスレッドが読んだ状態を作る）。
func pumpLive(t *testing.T, player *Player, source *fakeLiveSource, samples []float32) {
	t.Helper()
	const chunk = 4096
	out := make([]float32, chunk)
	for start := 0; start < len(samples); start += chunk {
		end := start + chunk
		if end > len(samples) {
			end = len(samples)
		}
		source.queue(samples[start:end])

		want := int64(end - start)
		deadline := time.Now().Add(2 * time.Second)
		for player.ringAvailable.Load() < want {
			if time.Now().After(deadline) {
				t.Fatalf("ライブサンプルがリングに届かない (available=%d, want=%d)", player.ringAvailable.Load(), want)
			}
			time.Sleep(time.Millisecond)
		}
		player.processAudio(out[:want])
	}
}

// sineSamples は 1 kHz 正弦波のインターリーブ済みサンプル列を作る。
func sineSamples(amp float64, seconds float64, sampleRate, channels int) []float32 {
	frames := int(float64(sampleRate) * seconds)
	samples := make([]float32, 0, frames*channels)
	for i := 0; i < frames; i++ {
		v := float32(amp * math.Sin(2*math.Pi*1000*float64(i)/float64(sampleRate)))
		for ch := 0; ch < channels; ch++ {
			samples = append(samples, v)
		}
	}
	return samples
}

// 実測ラウドネスから、掛けすぎた推定ゲインを取り戻す補正が決まること。
// 二重減衰（YouTube 側の減衰を知らずに再度減衰させた状態）の再現。
func TestLiveLoudnessCorrectionRecoversOverAttenuation(t *testing.T) {
	const sampleRate = 48000
	const channels = 2
	const targetLUFS = -18.0
	const amp = 0.4

	estimateGain := math.Pow(10, -10.69/20) // 掛けすぎた推定ゲイン

	source := newFakeLiveSource()
	player := newLiveTestPlayer()
	if err := player.playLiveSource(source, estimateGain); err != nil {
		t.Fatalf("playLiveSource: %v", err)
	}
	defer player.Stop()
	player.liveFadeTotal.Store(0)
	player.liveFadeRemaining.Store(0)

	player.StartLiveLoudnessCorrection(targetLUFS)
	pumpLive(t, player, source, sineSamples(amp, 2.0, sampleRate, channels))
	player.updateLiveCorrection()

	// 期待値: 同じ信号を測った参照メーターから求める。
	reference := newLoudnessMeter(sampleRate, channels)
	feedSine(reference, amp, 2.0, sampleRate, channels)
	measured, ok := reference.integratedLUFS()
	if !ok {
		t.Fatal("参照メーターが測定できていない")
	}
	want := resolveLiveCorrectionGain(measured, targetLUFS, estimateGain)

	got := player.liveCorrectionTargetGain()
	if math.Abs(20*math.Log10(got/want)) > 0.3 {
		t.Fatalf("補正ゲイン: got %.4f (%.2f dB), want %.4f (%.2f dB)",
			got, 20*math.Log10(got), want, 20*math.Log10(want))
	}

	// 総ゲイン（推定 × 補正）が「目標 − 実測」に一致すること。
	totalDB := 20 * math.Log10(estimateGain*got)
	if math.Abs(totalDB-(targetLUFS-measured)) > 0.3 {
		t.Fatalf("総ゲイン: got %.2f dB, want %.2f dB", totalDB, targetLUFS-measured)
	}
}

// 推定が既に正しければ補正は掛からないこと（1.0 付近）。
func TestLiveLoudnessCorrectionKeepsCorrectEstimate(t *testing.T) {
	const sampleRate = 48000
	const channels = 2
	const targetLUFS = -18.0
	const amp = 0.4

	reference := newLoudnessMeter(sampleRate, channels)
	feedSine(reference, amp, 2.0, sampleRate, channels)
	measured, _ := reference.integratedLUFS()
	estimateGain := math.Pow(10, (targetLUFS-measured)/20) // 完璧な推定

	source := newFakeLiveSource()
	player := newLiveTestPlayer()
	if err := player.playLiveSource(source, estimateGain); err != nil {
		t.Fatalf("playLiveSource: %v", err)
	}
	defer player.Stop()
	player.liveFadeTotal.Store(0)
	player.liveFadeRemaining.Store(0)

	player.StartLiveLoudnessCorrection(targetLUFS)
	pumpLive(t, player, source, sineSamples(amp, 2.0, sampleRate, channels))
	player.updateLiveCorrection()

	if got := player.liveCorrectionTargetGain(); math.Abs(20*math.Log10(got)) > 0.3 {
		t.Fatalf("補正不要のはず: got %.4f (%.2f dB)", got, 20*math.Log10(got))
	}
}

// 測定に足る音声が溜まる前は補正を掛けないこと（無音や再生直後の暴れ防止）。
func TestLiveLoudnessCorrectionWaitsForEnoughAudio(t *testing.T) {
	source := newFakeLiveSource()
	player := newLiveTestPlayer()
	if err := player.playLiveSource(source, 1.0); err != nil {
		t.Fatalf("playLiveSource: %v", err)
	}
	defer player.Stop()
	player.liveFadeTotal.Store(0)
	player.liveFadeRemaining.Store(0)

	player.StartLiveLoudnessCorrection(-18)
	pumpLive(t, player, source, sineSamples(0.4, 0.3, 48000, 2)) // 収束判定に足りない長さ
	player.updateLiveCorrection()

	if got := player.liveCorrectionTargetGain(); got != 1.0 {
		t.Fatalf("測定不足では補正なしのはず: got %v", got)
	}
}

// 補正ゲインは段差なく滑らかに移行すること（急な音量段差を作らない）。
func TestLiveCorrectionRampsSmoothly(t *testing.T) {
	source := newFakeLiveSource()
	player := newLiveTestPlayer()
	if err := player.playLiveSource(source, 1.0); err != nil {
		t.Fatalf("playLiveSource: %v", err)
	}
	defer player.Stop()
	player.liveFadeTotal.Store(0)
	player.liveFadeRemaining.Store(0)
	player.SetVolume(1.0)

	player.StartLiveLoudnessCorrection(-18)
	player.setLiveCorrectionTargetGain(2.0)

	pumpLive(t, player, source, sineSamples(0.1, 0.02, 48000, 2))

	current := player.liveCorrectionCurrentGain()
	if current <= 1.0 {
		t.Fatalf("補正が始まっていない: got %v", current)
	}
	if current >= 2.0 {
		t.Fatalf("補正が一瞬で跳んでいる（段差になる）: got %v", current)
	}
}

// 補正ゲインが出力に反映されること（推定ゲインと乗算される）。
func TestLiveCorrectionAppliesToOutput(t *testing.T) {
	source := newFakeLiveSource()
	player := newLiveTestPlayer()
	if err := player.playLiveSource(source, 0.5); err != nil {
		t.Fatalf("playLiveSource: %v", err)
	}
	defer player.Stop()
	player.liveFadeTotal.Store(0)
	player.liveFadeRemaining.Store(0)
	player.SetVolume(1.0)

	// ランプの途中を測らないよう、現在値・目標値ともに 1.5 へ据える。
	player.StartLiveLoudnessCorrection(-18)
	player.setLiveCorrectionTargetGain(1.5)
	player.setLiveCorrectionCurrentGain(1.5)

	source.queue([]float32{0.4, 0.4, 0.4, 0.4})
	deadline := time.Now().Add(2 * time.Second)
	for player.ringAvailable.Load() < 4 {
		if time.Now().After(deadline) {
			t.Fatalf("ライブサンプルがリングに届かない")
		}
		time.Sleep(time.Millisecond)
	}

	out := make([]float32, 4)
	player.processAudio(out)
	want := float32(0.4 * 0.5 * 1.5)
	for i, got := range out {
		if math.Abs(float64(got-want)) > 1e-6 {
			t.Fatalf("出力 %d: got %g, want %g (0.4 × baseGain 0.5 × 補正 1.5)", i, got, want)
		}
	}
}

// 停止時に補正状態が破棄されること（次のローカル曲へ持ち越さない）。
func TestLiveCorrectionResetsOnStop(t *testing.T) {
	source := newFakeLiveSource()
	player := newLiveTestPlayer()
	if err := player.playLiveSource(source, 1.0); err != nil {
		t.Fatalf("playLiveSource: %v", err)
	}
	player.StartLiveLoudnessCorrection(-18)
	player.setLiveCorrectionTargetGain(2.0)
	player.setLiveCorrectionCurrentGain(2.0)

	player.Stop()

	if got := player.liveCorrectionTargetGain(); got != 1.0 {
		t.Fatalf("停止後の目標補正: got %v, want 1.0", got)
	}
	if got := player.liveCorrectionCurrentGain(); got != 1.0 {
		t.Fatalf("停止後の現在補正: got %v, want 1.0", got)
	}
	if player.liveMeter.Load() != nil {
		t.Fatal("停止後もメーターが残っている")
	}
}
