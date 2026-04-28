package lyricssync

import (
	"os"
	"path/filepath"
	"testing"

	"ux-music-sidecar/internal/config"
)

func TestSyncDummyPipeline(t *testing.T) {
	t.Setenv("UX_MUSIC_LYRICS_SYNC_DUMMY", "1")
	t.Setenv("UX_MUSIC_MODEL_CACHE", t.TempDir())
	t.Setenv("UX_MUSIC_HF_DOWNLOAD", "none")

	dir := t.TempDir()
	audio := filepath.Join(dir, "silent.wav")
	if err := os.WriteFile(audio, []byte("fake"), 0600); err != nil {
		t.Fatal(err)
	}

	prevUD := config.GetUserDataPath()
	config.SetUserDataPath(dir)
	t.Cleanup(func() { config.SetUserDataPath(prevUD) })

	s := NewSyncer()
	res := s.Sync(Request{
		SongPath: audio,
		Lines:    []string{"hello", "world"},
		Language: "auto",
	})
	if !res.Success {
		t.Fatalf("%+v", res)
	}
	if len(res.Lines) != 2 {
		t.Fatalf("lines: %+v", res.Lines)
	}
}
