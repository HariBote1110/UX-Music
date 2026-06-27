package audio

import (
	"errors"
	"io"
	"testing"
	"time"
)

type fakeAudioStream struct {
	starts int
	stops  int
	closes int
}

func (s *fakeAudioStream) Start() error {
	s.starts++
	return nil
}

func (s *fakeAudioStream) Stop() error {
	s.stops++
	return nil
}

func (s *fakeAudioStream) Close() error {
	s.closes++
	return nil
}

// failingStartStream is a stream whose revival (Start) always fails with a
// non-recoverable error, modelling a cached output stream that has gone dead.
type failingStartStream struct {
	fakeAudioStream
}

func (s *failingStartStream) Start() error {
	s.starts++
	return errors.New("stream start failed")
}

type fakeDecoder struct{}

func (d fakeDecoder) Read(_ []byte) (int, error) { return 0, io.EOF }
func (d fakeDecoder) SampleRate() int            { return 44100 }
func (d fakeDecoder) Channels() int              { return 2 }
func (d fakeDecoder) Length() int64              { return 44100 }
func (d fakeDecoder) Seek(_ int64) error         { return nil }
func (d fakeDecoder) Close() error               { return nil }

func TestResumeRestartsPausedOutputStream(t *testing.T) {
	stream := &fakeAudioStream{}
	player := &Player{stream: stream}
	player.playing.Store(true)
	player.paused.Store(true)

	if err := player.Resume(); err != nil {
		t.Fatalf("resume failed: %v", err)
	}

	if stream.starts != 1 {
		t.Fatalf("expected Resume to start the existing stream once, got %d", stream.starts)
	}
	if player.paused.Load() {
		t.Fatal("expected Resume to clear paused state")
	}
}

func TestResumeRestartsTrackAfterLongPause(t *testing.T) {
	stream := &fakeAudioStream{}
	var restartedAt float64
	restartCalls := 0
	player := &Player{
		stream:     stream,
		decoder:    fakeDecoder{},
		sampleRate: 44100,
		restartTrack: func(position float64) error {
			restartCalls++
			restartedAt = position
			return nil
		},
	}
	player.playing.Store(true)
	player.paused.Store(true)
	// Simulate the decoder having advanced to ~10s before the long pause.
	player.position.Store(int64(10 * 44100))
	player.pausedSince.Store(time.Now().Add(-longPauseStreamRefreshAfter - time.Second).UnixNano())

	if err := player.Resume(); err != nil {
		t.Fatalf("resume failed: %v", err)
	}

	if restartCalls != 1 {
		t.Fatalf("expected the track to be rebuilt once after a long pause, got %d restarts", restartCalls)
	}
	if restartedAt < 9.9 || restartedAt > 10.1 {
		t.Fatalf("expected restart to resume near the saved position (~10s), got %.3fs", restartedAt)
	}
	// The wedged cached stream must not be reused after a long pause.
	if stream.starts != 0 {
		t.Fatalf("expected the cached stream not to be restarted after a long pause, got %d starts", stream.starts)
	}
}

// A short pause whose cached stream can no longer be revived must fall back to a
// full track rebuild rather than silently leaving playback wedged.
func TestResumeRestartsTrackWhenReviveFails(t *testing.T) {
	stream := &failingStartStream{}
	restartCalls := 0
	player := &Player{
		stream:     stream,
		decoder:    fakeDecoder{},
		sampleRate: 44100,
		restartTrack: func(_ float64) error {
			restartCalls++
			return nil
		},
	}
	player.playing.Store(true)
	player.paused.Store(true)

	if err := player.Resume(); err != nil {
		t.Fatalf("resume failed: %v", err)
	}

	if restartCalls != 1 {
		t.Fatalf("expected a full restart when reviving the stream fails, got %d restarts", restartCalls)
	}
}

func TestRestartCurrentTrackWithoutTrackErrors(t *testing.T) {
	player := &Player{}
	if err := player.restartCurrentTrack(0); err == nil {
		t.Fatal("expected restartCurrentTrack to error when no track is loaded")
	}
}
