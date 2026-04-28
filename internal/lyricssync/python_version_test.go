package lyricssync

import "testing"

func TestLyricsDummyModeEnabledInEnv(t *testing.T) {
	t.Setenv("UX_MUSIC_LYRICS_SYNC_DUMMY", "")
	if lyricsDummyModeEnabledInEnv() {
		t.Fatal("expected false when empty")
	}
	t.Setenv("UX_MUSIC_LYRICS_SYNC_DUMMY", "1")
	if !lyricsDummyModeEnabledInEnv() {
		t.Fatal("expected true for 1")
	}
}
