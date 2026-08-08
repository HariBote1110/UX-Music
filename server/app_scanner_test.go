package server

import (
	"reflect"
	"strings"
	"testing"

	"ux-music-sidecar/internal/scanner"
)

func TestSortSongsForLibraryOrdersByAlbumDiscTrack(t *testing.T) {
	songs := []scanner.Song{
		{
			Path:        "/music/A/Album/03-second.flac",
			Artist:      "A",
			Album:       "Album",
			DiscNumber:  1,
			TrackNumber: 3,
			Title:       "Second",
		},
		{
			Path:        "/music/A/Album/01-first.flac",
			Artist:      "A",
			Album:       "Album",
			DiscNumber:  1,
			TrackNumber: 1,
			Title:       "First",
		},
		{
			Path:        "/music/A/Album/201-disc2.flac",
			Artist:      "A",
			Album:       "Album",
			DiscNumber:  2,
			TrackNumber: 1,
			Title:       "Disc2 First",
		},
	}

	sortSongsForLibrary(songs)

	got := []string{songs[0].Path, songs[1].Path, songs[2].Path}
	want := []string{
		"/music/A/Album/01-first.flac",
		"/music/A/Album/03-second.flac",
		"/music/A/Album/201-disc2.flac",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("sortSongsForLibrary() order = %#v, want %#v", got, want)
	}
}

func TestSortSongsForLibraryUnknownTrackFallsBackToTitleAndPath(t *testing.T) {
	songs := []scanner.Song{
		{
			Path:        "/music/A/Album/z-last.flac",
			Artist:      "A",
			Album:       "Album",
			DiscNumber:  1,
			TrackNumber: 0,
			Title:       "Zeta",
		},
		{
			Path:        "/music/A/Album/a-first.flac",
			Artist:      "A",
			Album:       "Album",
			DiscNumber:  1,
			TrackNumber: 0,
			Title:       "Alpha",
		},
		{
			Path:        "/music/A/Album/02-known.flac",
			Artist:      "A",
			Album:       "Album",
			DiscNumber:  1,
			TrackNumber: 2,
			Title:       "Known",
		},
	}

	sortSongsForLibrary(songs)

	got := []string{songs[0].Path, songs[1].Path, songs[2].Path}
	want := []string{
		"/music/A/Album/02-known.flac",
		"/music/A/Album/a-first.flac",
		"/music/A/Album/z-last.flac",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("sortSongsForLibrary() fallback order = %#v, want %#v", got, want)
	}
}

// sanitiseFileName は paired peer から届いたファイル名 / albumartist が
// そのままファイルシステムへ書かれる直前の唯一のガードなので、実際の挙動を
// リテラルで固定しておく（希望する挙動ではなく現状の挙動を記述する）。
func TestSanitiseFileName(t *testing.T) {
	longName := strings.Repeat("a", 300)
	cases := []struct {
		name  string
		input string
		want  string
	}{
		{name: "empty", input: "", want: "_"},
		{name: "whitespace only", input: "   ", want: "_"},
		{name: "parent dir", input: "..", want: "_"},
		{name: "dots only", input: "....", want: "_"},
		{name: "single dot", input: ".", want: "_"},
		// パス区切りは "_" に置換されるだけで、途中の ".." は文字として残る。
		{name: "relative traversal", input: "../../x", want: ".._.._x"},
		{name: "traversal without tail", input: "../..", want: ".._"},
		{name: "forward slash", input: "a/b", want: "a_b"},
		{name: "back slash", input: `a\b`, want: "a_b"},
		{name: "absolute path", input: "/etc/passwd", want: "_etc_passwd"},
		{name: "windows reserved chars", input: `a:b*c?d"e<f>g|h`, want: "a_b_c_d_e_f_g_h"},
		// 末尾の "." と " " のみ削られる（先頭は削られない）。
		{name: "trailing dot and space", input: "song.flac. ", want: "song.flac"},
		{name: "leading dot kept", input: ".hidden", want: ".hidden"},
		// 長さ上限は無い。300 文字はそのまま通る。
		{name: "very long name", input: longName, want: longName},
		{name: "normal name", input: "song.flac", want: "song.flac"},
		{name: "japanese name", input: "夜に駆ける.flac", want: "夜に駆ける.flac"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := sanitiseFileName(tc.input); got != tc.want {
				t.Fatalf("sanitiseFileName(%q) = %q, want %q", tc.input, got, tc.want)
			}
		})
	}
}
