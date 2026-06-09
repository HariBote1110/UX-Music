package audio

import (
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

func TestResumeReopensStreamAfterLongPause(t *testing.T) {
	oldStream := &fakeAudioStream{}
	newStream := &fakeAudioStream{}
	player := &Player{
		stream:  oldStream,
		decoder: fakeDecoder{},
		openOutputStream: func() (audioStream, error) {
			return newStream, nil
		},
	}
	player.playing.Store(true)
	player.paused.Store(true)
	player.pausedSince.Store(time.Now().Add(-longPauseStreamRefreshAfter - time.Second).UnixNano())

	if err := player.Resume(); err != nil {
		t.Fatalf("resume failed: %v", err)
	}

	if oldStream.stops != 1 || oldStream.closes != 1 {
		t.Fatalf("expected old stream to be stopped and closed, got stops=%d closes=%d", oldStream.stops, oldStream.closes)
	}
	if newStream.starts != 1 {
		t.Fatalf("expected reopened stream to start once, got %d", newStream.starts)
	}
	if player.stream != newStream {
		t.Fatal("expected player to use reopened stream")
	}
}
