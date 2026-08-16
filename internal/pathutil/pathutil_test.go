package pathutil

import (
	stdpath "path"
	"path/filepath"
	"reflect"
	"strings"
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

// TestCandidateForms は期待値を stdlib のプリミティブ（filepath.Clean /
// strings.ReplaceAll+path.Clean / norm.NFC / norm.NFD）から機械的に組み立てる。
// CandidateForms 自身を呼んで期待値を作ると実装のバグをそのまま期待値にコピー
// してしまい退行を検出できないため、production の関数は一切呼ばない。
//
// 期待される候補は次の 3 系統 × NFC/NFD 正規化:
//   - trimmed:  前後空白を除いただけの入力
//   - cleaned:  filepath.Clean（現在の OS のセパレータ規約）
//   - slash:    "\" を "/" に置き換えたうえで path.Clean（OS に依存しない
//     POSIX 形式）。CandidateForms の実装で filepath.Clean を使わないのは、
//     filepath.Clean が Windows では入力のセパレータ規約に関係なく常に "\"
//     を出力するため、POSIX で書かれたライブラリの候補が失われるから。
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

	slashClean := func(s string) string {
		return stdpath.Clean(strings.ReplaceAll(s, "\\", "/"))
	}
	uniq := func(items ...string) []string {
		seen := make(map[string]struct{}, len(items))
		out := make([]string, 0, len(items))
		for _, it := range items {
			if it == "" {
				continue
			}
			if _, ok := seen[it]; ok {
				continue
			}
			seen[it] = struct{}{}
			out = append(out, it)
		}
		return out
	}

	cases := []struct {
		name  string
		input string
	}{
		{name: "blank", input: "   "},
		{name: "empty", input: ""},
		{name: "nfc with trailing slash and spaces", input: "  /music/" + nfcKa + "/song.flac/  "},
		{name: "nfd input", input: "/music/" + nfdKa + "/song.flac"},
		{name: "ascii needing clean", input: "/a/b/../c/song.mp3"},
		{name: "ascii already clean", input: "/a/c/song.mp3"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			trimmed := strings.TrimSpace(tc.input)
			var want []string
			if trimmed != "" {
				cleaned := filepath.Clean(trimmed)
				slash := slashClean(trimmed)
				want = uniq(
					trimmed, cleaned, slash,
					norm.NFC.String(cleaned), norm.NFD.String(cleaned),
					norm.NFC.String(slash), norm.NFD.String(slash),
				)
			}
			if got := CandidateForms(tc.input); !reflect.DeepEqual(got, want) {
				t.Errorf("CandidateForms(%q) = %#v, want %#v", tc.input, got, want)
			}
		})
	}
}

// TestCandidateFormsResolvesAcrossPlatforms states the functional
// requirement directly, independent of the OS running the test:
// library.json is written once but may be opened by the app on a different
// OS than the one that created it. A path stored in POSIX form by a
// macOS-built library must still be offered as a lookup candidate when the
// app later runs on Windows (filepath.Clean alone would rewrite "/" to "\"
// and silently break the match), and a path stored with backslashes by a
// Windows-built library must still be offered as a candidate when the app
// later runs on macOS/Linux.
func TestCandidateFormsResolvesAcrossPlatforms(t *testing.T) {
	posixStored := "/Music/" + "\u30ac" + "/song.flac"
	posixWant := "/Music/\u30ac/song.flac"
	if got := CandidateForms(posixStored); !containsString(got, posixWant) {
		t.Errorf("CandidateForms(%q) = %v, missing the POSIX form %q needed to resolve a macOS-created library entry on Windows", posixStored, got, posixWant)
	}

	windowsStored := `C:\Music\` + "\u30ac" + `\song.flac`
	windowsWant := "C:/Music/\u30ac/song.flac"
	if got := CandidateForms(windowsStored); !containsString(got, windowsWant) {
		t.Errorf("CandidateForms(%q) = %v, missing the slash form %q needed to resolve a Windows-created library entry on macOS/Linux", windowsStored, got, windowsWant)
	}
}

func containsString(list []string, want string) bool {
	for _, item := range list {
		if item == want {
			return true
		}
	}
	return false
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

// TestSlashCandidateFormsResolvesAcrossPlatforms states the same
// cross-platform requirement as TestCandidateFormsResolvesAcrossPlatforms,
// for the SlashCandidateForms consumer (remotePlaylistPathToSongID): a
// playlist line written on macOS (POSIX separators) must still match a
// library key looked up on Windows. Regression guard for the bug where
// filepath.Clean(filepath.ToSlash(path)) silently re-introduced "\" on
// Windows, defeating the whole point of a "slash form" candidate.
func TestSlashCandidateFormsResolvesAcrossPlatforms(t *testing.T) {
	posixStored := "/Volumes/lib/../lib/album/track.m4a"
	want := "/Volumes/lib/album/track.m4a"
	if got := SlashCandidateForms(posixStored); !containsString(got, want) {
		t.Errorf("SlashCandidateForms(%q) = %v, missing the cleaned POSIX form %q needed to resolve on Windows", posixStored, got, want)
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
