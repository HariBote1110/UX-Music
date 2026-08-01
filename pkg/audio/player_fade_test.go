package audio

import (
	"testing"
	"time"
)

// ライブ再生（プロセスタップ）開始時、出力を無音から短時間でランプさせる
// フェードインが張られること。埋め込みはミュート開始でタップ確立後に音を
// 出すが、フェードは捕捉ストリーム先頭のクリック / DC 段差もならす保険。
func TestPlayLiveSourceArmsStartFade(t *testing.T) {
	source := newFakeLiveSource()
	player := newLiveTestPlayer()
	if err := player.playLiveSource(source, 1.0); err != nil {
		t.Fatalf("playLiveSource: %v", err)
	}
	defer player.Stop()

	// 仕様: フェード長 0.12 秒 @ 48kHz / 2ch = 48000 * 0.12 * 2 = 11520 サンプル。
	// 本番と同じ式を書くと liveStartFadeSeconds を変えてもテストが追随して
	// しまうため、期待値はリテラルで固定する。フェード長を変える際はここも
	// 意図的に書き換えること。
	const want int64 = 11520
	if got := player.liveFadeTotal.Load(); got != want {
		t.Fatalf("fade total: got %d, want %d", got, want)
	}
	if got := player.liveFadeRemaining.Load(); got != want {
		t.Fatalf("fade remaining at start: got %d, want %d", got, want)
	}
}

// フェード係数は 0 から単調増加し、定常フル出力（1.0）を超えないこと。
// 一定振幅 1.0 の入力に対し factor = 1 - remaining/total を検証する。
func TestLiveStartFadeRampsOutputFromSilence(t *testing.T) {
	source := newFakeLiveSource()
	player := newLiveTestPlayer()
	if err := player.playLiveSource(source, 1.0); err != nil {
		t.Fatalf("playLiveSource: %v", err)
	}
	defer player.Stop()
	player.SetVolume(1.0)

	// 決定的に検証するためフェード長を 8 サンプルへ縮める。
	player.liveFadeTotal.Store(8)
	player.liveFadeRemaining.Store(8)

	source.queue([]float32{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1})
	deadline := time.Now().Add(2 * time.Second)
	for player.ringAvailable.Load() < 8 {
		if time.Now().After(deadline) {
			t.Fatalf("live samples never reached playback ring (available=%d)", player.ringAvailable.Load())
		}
		time.Sleep(5 * time.Millisecond)
	}

	out := make([]float32, 8)
	player.processAudio(out)

	for i := 0; i < 8; i++ {
		want := float32(i) / 8
		if diff := out[i] - want; diff > 1e-6 || diff < -1e-6 {
			t.Fatalf("fade sample %d: got %g, want %g", i, out[i], want)
		}
		if out[i] >= 1.0 {
			t.Fatalf("fade sample %d must stay below steady 1.0, got %g", i, out[i])
		}
		if i > 0 && out[i] <= out[i-1] {
			t.Fatalf("fade must increase monotonically: out[%d]=%g <= out[%d]=%g", i, out[i], i-1, out[i-1])
		}
	}
	if rem := player.liveFadeRemaining.Load(); rem != 0 {
		t.Fatalf("fade remaining after ramp: got %d, want 0", rem)
	}

	// フェード完了後は定常フル出力に戻ること。
	source.queue([]float32{1, 1, 1, 1})
	for player.ringAvailable.Load() < 4 {
		if time.Now().After(deadline) {
			t.Fatalf("second batch never reached playback ring")
		}
		time.Sleep(5 * time.Millisecond)
	}
	out2 := make([]float32, 4)
	player.processAudio(out2)
	for i, got := range out2 {
		if diff := got - 1.0; diff > 1e-6 || diff < -1e-6 {
			t.Fatalf("post-fade sample %d: got %g, want 1.0", i, got)
		}
	}
}
