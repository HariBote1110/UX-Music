package audio

import (
	"io"
	"sync"
	"testing"
	"time"
)

// ---- normaliseTapTargets ----

func TestNormaliseTapTargetsTrimsAndDeduplicates(t *testing.T) {
	t.Parallel()
	got, err := normaliseTapTargets(ProcessTapTargets{
		BundleIDs: []string{" com.apple.WebKit.GPU ", "", "com.apple.WebKit.GPU", "com.apple.WebKit.WebContent"},
		PIDs:      []int{123, 0, -5, 123, 456},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	wantBundles := []string{"com.apple.WebKit.GPU", "com.apple.WebKit.WebContent"}
	if len(got.BundleIDs) != len(wantBundles) {
		t.Fatalf("bundle IDs: got %v, want %v", got.BundleIDs, wantBundles)
	}
	for i, want := range wantBundles {
		if got.BundleIDs[i] != want {
			t.Fatalf("bundle IDs[%d]: got %q, want %q", i, got.BundleIDs[i], want)
		}
	}
	wantPIDs := []int{123, 456}
	if len(got.PIDs) != len(wantPIDs) {
		t.Fatalf("PIDs: got %v, want %v", got.PIDs, wantPIDs)
	}
	for i, want := range wantPIDs {
		if got.PIDs[i] != want {
			t.Fatalf("PIDs[%d]: got %d, want %d", i, got.PIDs[i], want)
		}
	}
}

func TestNormaliseTapTargetsRejectsEmpty(t *testing.T) {
	t.Parallel()
	if _, err := normaliseTapTargets(ProcessTapTargets{}); err == nil {
		t.Fatal("expected error for empty targets")
	}
	if _, err := normaliseTapTargets(ProcessTapTargets{BundleIDs: []string{"  "}, PIDs: []int{0, -1}}); err == nil {
		t.Fatal("expected error when all targets are invalid")
	}
}

// ---- fake live source ----

type fakeLiveSource struct {
	mu         sync.Mutex
	samples    []float32
	sampleRate int
	channels   int
	stopCalls  int
}

func newFakeLiveSource() *fakeLiveSource {
	return &fakeLiveSource{sampleRate: 48000, channels: 2}
}

func (s *fakeLiveSource) queue(samples []float32) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.samples = append(s.samples, samples...)
}

func (s *fakeLiveSource) ReadSamples(dst []float32) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := copy(dst, s.samples)
	s.samples = s.samples[n:]
	return n
}

func (s *fakeLiveSource) SampleRate() int { return s.sampleRate }
func (s *fakeLiveSource) Channels() int   { return s.channels }

func (s *fakeLiveSource) Stop() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.stopCalls++
	return nil
}

func (s *fakeLiveSource) stopCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.stopCalls
}

// ---- liveTapDecoder ----

func TestLiveTapDecoderDeliversQueuedSamples(t *testing.T) {
	t.Parallel()
	source := newFakeLiveSource()
	source.queue([]float32{0.1, -0.2, 0.3})
	dec := newLiveTapDecoder(source)
	defer dec.Close()

	dst := make([]float32, 8)
	n, err := dec.ReadFloat32(dst)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if n != 3 {
		t.Fatalf("read: got %d, want 3", n)
	}
	if dst[0] != 0.1 || dst[1] != -0.2 || dst[2] != 0.3 {
		t.Fatalf("samples: got %v", dst[:3])
	}
}

func TestLiveTapDecoderInjectsSilenceWhenSourceIdle(t *testing.T) {
	t.Parallel()
	source := newFakeLiveSource()
	dec := newLiveTapDecoder(source)
	defer dec.Close()

	dst := make([]float32, 4096)
	for i := range dst {
		dst[i] = 99 // 上書き確認用の番兵値
	}
	start := time.Now()
	n, err := dec.ReadFloat32(dst)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if n <= 0 {
		t.Fatal("expected silence injection to return samples, got 0 (would end the track)")
	}
	for i := 0; i < n; i++ {
		if dst[i] != 0 {
			t.Fatalf("expected silence, got %g at %d", dst[i], i)
		}
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("silence injection took too long: %v", elapsed)
	}
}

func TestLiveTapDecoderReturnsEOFAfterClose(t *testing.T) {
	t.Parallel()
	source := newFakeLiveSource()
	dec := newLiveTapDecoder(source)

	if err := dec.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	if source.stopCount() != 1 {
		t.Fatalf("expected source.Stop once, got %d", source.stopCount())
	}
	// Close は冪等
	if err := dec.Close(); err != nil {
		t.Fatalf("second close: %v", err)
	}
	if source.stopCount() != 1 {
		t.Fatalf("expected Stop to remain 1 after second close, got %d", source.stopCount())
	}

	dst := make([]float32, 16)
	n, err := dec.ReadFloat32(dst)
	if n != 0 || err != io.EOF {
		t.Fatalf("read after close: got (%d, %v), want (0, io.EOF)", n, err)
	}
}

func TestLiveTapDecoderReportsLiveMetadata(t *testing.T) {
	t.Parallel()
	source := newFakeLiveSource()
	dec := newLiveTapDecoder(source)
	defer dec.Close()

	if dec.SampleRate() != 48000 {
		t.Fatalf("sample rate: got %d, want 48000", dec.SampleRate())
	}
	if dec.Channels() != 2 {
		t.Fatalf("channels: got %d, want 2", dec.Channels())
	}
	if dec.Length() != 0 {
		t.Fatalf("length: got %d, want 0 (live source has no duration)", dec.Length())
	}
	if err := dec.Seek(12345); err != nil {
		t.Fatalf("seek must be a no-op for live sources: %v", err)
	}
}

// ---- Player ライブモード ----

func newLiveTestPlayer() *Player {
	return &Player{
		openOutputStream: func() (audioStream, error) {
			return &fakeAudioStream{}, nil
		},
	}
}

func TestPlayLiveSourceUsesTapFormatAndDisablesPositionDuration(t *testing.T) {
	source := newFakeLiveSource()
	player := newLiveTestPlayer()

	if err := player.playLiveSource(source, 1.0); err != nil {
		t.Fatalf("playLiveSource: %v", err)
	}
	defer player.Stop()

	// 出力ストリームはタップのフォーマット（48kHz/2ch）で開かれること。
	// 44.1kHz のまま流すとリサンプル無しで約9%低いピッチになる。
	player.mu.RLock()
	sampleRate, channels := player.sampleRate, player.channels
	player.mu.RUnlock()
	if sampleRate != 48000 {
		t.Fatalf("player sample rate: got %d, want 48000 (tap format)", sampleRate)
	}
	if channels != 2 {
		t.Fatalf("player channels: got %d, want 2", channels)
	}

	if !player.IsPlaying() {
		t.Fatal("expected live playback to report playing")
	}
	// ライブソースには位置・総時間の概念が無い。
	player.position.Store(48000 * 10)
	if got := player.GetPosition(); got != 0 {
		t.Fatalf("live position: got %g, want 0", got)
	}
	if got := player.GetDuration(); got != 0 {
		t.Fatalf("live duration: got %g, want 0", got)
	}
	if err := player.Seek(30); err != nil {
		t.Fatalf("live seek must be a harmless no-op: %v", err)
	}
}

func TestStopTearsDownLiveSourceAndRestoresNormalState(t *testing.T) {
	source := newFakeLiveSource()
	player := newLiveTestPlayer()

	if err := player.playLiveSource(source, 1.0); err != nil {
		t.Fatalf("playLiveSource: %v", err)
	}
	if err := player.Stop(); err != nil {
		t.Fatalf("stop: %v", err)
	}

	if source.stopCount() != 1 {
		t.Fatalf("expected capture Stop once on player Stop, got %d", source.stopCount())
	}
	player.mu.RLock()
	decoder := player.decoder
	currentPath := player.currentPath
	player.mu.RUnlock()
	if decoder != nil {
		t.Fatal("expected live decoder to be cleared on Stop")
	}
	if currentPath != "" {
		t.Fatalf("expected currentPath cleared, got %q", currentPath)
	}

	// ライブモード解除後は通常の位置計算に戻ること。
	player.mu.Lock()
	player.sampleRate = 44100
	player.mu.Unlock()
	player.position.Store(44100 * 2)
	if got := player.GetPosition(); got != 2 {
		t.Fatalf("position after live teardown: got %g, want 2", got)
	}
}

func TestPlayLiveSourceFeedsSamplesIntoPlaybackRing(t *testing.T) {
	source := newFakeLiveSource()
	source.queue([]float32{0.5, 0.5, 0.5, 0.5})
	player := newLiveTestPlayer()

	if err := player.playLiveSource(source, 1.0); err != nil {
		t.Fatalf("playLiveSource: %v", err)
	}
	defer player.Stop()

	deadline := time.Now().Add(2 * time.Second)
	for player.ringAvailable.Load() < 4 {
		if time.Now().After(deadline) {
			t.Fatalf("live samples never reached playback ring (available=%d)", player.ringAvailable.Load())
		}
		time.Sleep(5 * time.Millisecond)
	}

	// リング先頭に float32 のまま（量子化なしで）書かれていること。
	readPos := player.ringReadPos.Load()
	for i := int64(0); i < 4; i++ {
		got := player.ringBuf[(readPos+i)%int64(player.ringBufSize)]
		if got != 0.5 {
			t.Fatalf("ring sample %d: got %g, want 0.5", i, got)
		}
	}
}
