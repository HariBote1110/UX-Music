package pathutil

import (
	"path/filepath"
	"reflect"
	"testing"

	"golang.org/x/text/unicode/norm"
)

// TestCanonicalisePath verifies Clean + NFC normalisation.
func TestCanonicalisePath(t *testing.T) {
	// "ガ" as NFD (カ + combining voiced mark) should become NFC form.
	nfdPath := "/music/" + norm.NFD.String("ガ") + "/./song.flac"
	want := filepath.Clean("/music/" + norm.NFC.String("ガ") + "/song.flac")
	if got := CanonicalisePath(nfdPath); got != want {
		t.Errorf("CanonicalisePath(%q) = %q, want %q", nfdPath, got, want)
	}
	if got := CanonicalisePath(""); got != "" {
		t.Errorf("CanonicalisePath(\"\") = %q, want empty", got)
	}
}

// TestNFC verifies simple NFC conversion.
func TestNFC(t *testing.T) {
	nfd := norm.NFD.String("パス")
	if got := NFC(nfd); got != norm.NFC.String("パス") {
		t.Errorf("NFC(%q) = %q", nfd, got)
	}
}

// TestCandidateForms は期待値をリテラルで固定する。
// 以前は本番と同じ手順（trim → Clean → NFC → NFD → dedupe）をテスト側で
// 書き写して比較していたため、実装を変えると期待値も一緒に変わってしまい
// 退行を検出できなかった。
//
// 濁点付き仮名は NFC が "ガ"(U+30AC) 1 文字、NFD が "カ"(U+30AB) +
// 濁点(U+3099) の 2 文字になる。macOS のファイルシステムは NFD を返すため
// 両形が候補に並ぶことが重要。
func TestCandidateForms(t *testing.T) {
	// ソースが正規化されても壊れないようエスケープで書く。
	const (
		nfcKa = "\u30ac"       // ガ (NFC)
		nfdKa = "\u30ab\u3099" // カ + 濁点符 (NFD)
	)
	cases := []struct {
		name  string
		input string
		want  []string
	}{
		{name: "blank", input: "   ", want: nil},
		{name: "empty", input: "", want: nil},
		{
			// 前後空白 + 末尾スラッシュ付きの NFC 入力。
			name:  "nfc with trailing slash and spaces",
			input: "  /music/" + nfcKa + "/song.flac/  ",
			want: []string{
				"/music/" + nfcKa + "/song.flac/",
				"/music/" + nfcKa + "/song.flac",
				"/music/" + nfdKa + "/song.flac",
			},
		},
		{
			// NFD 入力。trimmed == cleaned == nfd なので候補は NFD と NFC の 2 件。
			name:  "nfd input",
			input: "/music/" + nfdKa + "/song.flac",
			want: []string{
				"/music/" + nfdKa + "/song.flac",
				"/music/" + nfcKa + "/song.flac",
			},
		},
		{
			// ASCII のみ。NFC/NFD は cleaned と同一なので dedupe されて 2 件。
			name:  "ascii needing clean",
			input: "/a/b/../c/song.mp3",
			want: []string{
				"/a/b/../c/song.mp3",
				"/a/c/song.mp3",
			},
		},
		{
			// すでに正規形の ASCII は 1 件だけ。
			name:  "ascii already clean",
			input: "/a/c/song.mp3",
			want:  []string{"/a/c/song.mp3"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := CandidateForms(tc.input); !reflect.DeepEqual(got, tc.want) {
				t.Errorf("CandidateForms(%q) = %#v, want %#v", tc.input, got, tc.want)
			}
		})
	}
}

// TestSlashCandidateForms mirrors wearPlaylistPathToSongID key candidates.
func TestSlashCandidateForms(t *testing.T) {
	path := "/a/b/../c/song.mp3"
	got := SlashCandidateForms(path)
	if len(got) == 0 {
		t.Fatalf("SlashCandidateForms returned no candidates")
	}
	// Must contain the raw path first and the cleaned form.
	if got[0] != path {
		t.Errorf("first candidate = %q, want raw path %q", got[0], path)
	}
	foundClean := false
	for _, c := range got {
		if c == filepath.Clean(path) {
			foundClean = true
		}
	}
	if !foundClean {
		t.Errorf("cleaned form %q missing from %v", filepath.Clean(path), got)
	}
}

// TestSamePath mirrors the scanner samePath helper behaviour.
func TestSamePath(t *testing.T) {
	if !SamePath("/a/b/../c", "/a/c") {
		t.Errorf("SamePath should treat /a/b/../c and /a/c as equal")
	}
	if SamePath("/a/c", "/a/d") {
		t.Errorf("SamePath should treat different paths as unequal")
	}
}
