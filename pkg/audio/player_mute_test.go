package audio

import "testing"

// newTestPlayerWithSamples builds a minimal Player able to run processAudio
// without touching PortAudio: playing/unpaused, unity volume/baseGain, ring
// buffer pre-filled with a known non-zero sample and no EQ active.
func newTestPlayerWithSamples(samples []float32) *Player {
	p := &Player{}
	p.setVolume(1.0)
	p.baseGain.Store(0) // overwritten below via SetNormalisationGain-equivalent
	p.eqConfig.Store(defaultEqualizerConfig())
	p.channels = 2
	p.ringBufSize = len(samples)
	p.ringBuf = make([]float32, len(samples))
	copy(p.ringBuf, samples)
	p.ringReadPos.Store(0)
	p.ringAvailable.Store(int64(len(samples)))
	p.playing.Store(true)
	p.paused.Store(false)
	p.SetNormalisationGain(1.0)
	return p
}

func TestProcessAudio_UnmutedOutputsSamples(t *testing.T) {
	p := newTestPlayerWithSamples([]float32{0.5, 0.5, 0.5, 0.5})
	out := make([]float32, 4)
	p.processAudio(out)
	for i, s := range out {
		if s == 0 {
			t.Errorf("out[%d] = 0, want non-zero when unmuted", i)
		}
	}
}

func TestProcessAudio_LocalMutedOutputsSilence(t *testing.T) {
	p := newTestPlayerWithSamples([]float32{0.5, 0.5, 0.5, 0.5})
	p.SetLocalMuted(true)
	out := make([]float32, 4)
	p.processAudio(out)
	for i, s := range out {
		if s != 0 {
			t.Errorf("out[%d] = %v, want 0 when locally muted", i, s)
		}
	}
}

func TestProcessAudio_LocalMutedStillAdvancesPosition(t *testing.T) {
	p := newTestPlayerWithSamples([]float32{0.5, 0.5, 0.5, 0.5})
	p.SetLocalMuted(true)
	out := make([]float32, 4)
	p.processAudio(out)
	if got := p.position.Load(); got != 2 {
		t.Errorf("position after muted callback = %d, want 2 (samplesToRead/channels)", got)
	}
	if got := p.ringAvailable.Load(); got != 0 {
		t.Errorf("ringAvailable after muted callback = %d, want 0 (ring still drained)", got)
	}
}

func TestSetLocalMuted_IsLocalMutedRoundTrip(t *testing.T) {
	p := &Player{}
	if p.IsLocalMuted() {
		t.Fatal("new Player should start unmuted")
	}
	p.SetLocalMuted(true)
	if !p.IsLocalMuted() {
		t.Error("IsLocalMuted() = false after SetLocalMuted(true)")
	}
	p.SetLocalMuted(false)
	if p.IsLocalMuted() {
		t.Error("IsLocalMuted() = true after SetLocalMuted(false)")
	}
}
