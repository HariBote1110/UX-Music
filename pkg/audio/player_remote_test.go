package audio

import "testing"

// TestIsRemoteSource は再生ソースがリモート URL（http/https）かどうかの
// 判定を検証する。YouTube ストリーミング再生では googlevideo の HTTPS URL を
// ffmpeg デコーダーへ直接渡すため、ローカルパスとの振り分けが要になる。
func TestIsRemoteSource(t *testing.T) {
	cases := []struct {
		name   string
		source string
		want   bool
	}{
		{"HTTPS の URL", "https://rr4---sn-oguelnzy.googlevideo.com/videoplayback?itag=251", true},
		{"HTTP の URL", "http://example.com/audio.m4a", true},
		{"大文字混在スキーム", "HTTPS://Example.com/a.webm", true},
		{"絶対ローカルパス", "/Users/yuki/Music/song.mp3", false},
		{"Windows 風パス", `C:\Music\song.flac`, false},
		{"相対パス", "songs/track.m4a", false},
		{"http を含むだけのファイル名", "/tmp/https-notes.txt", false},
		{"空文字", "", false},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := isRemoteSource(tc.source); got != tc.want {
				t.Errorf("isRemoteSource(%q) = %v, want %v", tc.source, got, tc.want)
			}
		})
	}
}
