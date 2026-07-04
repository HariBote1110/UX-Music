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

// TestCandidateForms mirrors the historical loudnessPathCandidates behaviour:
// trimmed, cleaned, NFC and NFD forms, deduplicated, order preserved.
func TestCandidateForms(t *testing.T) {
	if got := CandidateForms("   "); got != nil {
		t.Errorf("CandidateForms(blank) = %v, want nil", got)
	}

	raw := "  /music/ガ/song.flac/  " // NFC input with trailing slash + spaces
	got := CandidateForms(raw)
	trimmed := "/music/ガ/song.flac/"
	cleaned := filepath.Clean(trimmed)
	nfc := norm.NFC.String(cleaned)
	nfd := norm.NFD.String(cleaned)

	want := make([]string, 0, 4)
	seen := map[string]struct{}{}
	for _, c := range []string{trimmed, cleaned, nfc, nfd} {
		if c == "" {
			continue
		}
		if _, ok := seen[c]; ok {
			continue
		}
		seen[c] = struct{}{}
		want = append(want, c)
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("CandidateForms(%q) = %v, want %v", raw, got, want)
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
