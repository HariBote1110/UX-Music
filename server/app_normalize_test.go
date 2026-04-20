package server

import (
	"reflect"
	"testing"

	"golang.org/x/text/unicode/norm"
)

func TestRehydrateNormalizeFilesPreservesPaths(t *testing.T) {
	in := []interface{}{
		map[string]interface{}{"id": "a", "path": "/Music/x.flac", "gain": float64(-1)},
	}
	out := rehydrateNormalizeFiles(in)
	if len(out) != 1 {
		t.Fatalf("len = %d", len(out))
	}
	m, ok := out[0].(map[string]interface{})
	if !ok {
		t.Fatalf("element type %T", out[0])
	}
	if m["path"] != "/Music/x.flac" {
		t.Fatalf("path = %v", m["path"])
	}
}

func TestHasNumericLoudnessValue(t *testing.T) {
	tests := []struct {
		name  string
		value interface{}
		want  bool
	}{
		{name: "float64", value: float64(-12.3), want: true},
		{name: "int", value: int(-10), want: true},
		{name: "string", value: "-12.3", want: false},
		{name: "nil", value: nil, want: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := hasNumericLoudnessValue(tt.value)
			if got != tt.want {
				t.Fatalf("hasNumericLoudnessValue(%v) = %v, want %v", tt.value, got, tt.want)
			}
		})
	}
}

func TestFilterPendingLoudnessPaths(t *testing.T) {
	paths := []string{
		"",
		"  /music/a.flac  ",
		"/music/b.flac",
		"/music/a.flac",
		"/music/c.flac",
	}
	existing := map[string]interface{}{
		"/music/a.flac": float64(-11.2),
		"/music/c.flac": "pending",
	}

	got := filterPendingLoudnessPaths(paths, existing)
	want := []string{"/music/b.flac", "/music/c.flac"}

	if !reflect.DeepEqual(got, want) {
		t.Fatalf("filterPendingLoudnessPaths() = %#v, want %#v", got, want)
	}
}

func TestLoudnessPathCandidates(t *testing.T) {
	pathNFD := "/Users/yuki/Music/バンド/曲.flac"
	pathNFC := norm.NFC.String(pathNFD)

	candidates := loudnessPathCandidates(pathNFD)
	if len(candidates) == 0 {
		t.Fatalf("loudnessPathCandidates returned empty")
	}

	hasNFD := false
	hasNFC := false
	for _, candidate := range candidates {
		if candidate == pathNFD {
			hasNFD = true
		}
		if candidate == pathNFC {
			hasNFC = true
		}
	}

	if !hasNFD || !hasNFC {
		t.Fatalf("expected both NFD and NFC candidates, got %#v", candidates)
	}
}

func TestHasStoredNumericLoudness(t *testing.T) {
	pathNFD := "/Users/yuki/Music/バンド/曲.flac"
	pathNFC := norm.NFC.String(pathNFD)

	existing := map[string]interface{}{
		pathNFC: float64(-9.5),
	}
	if !hasStoredNumericLoudness(existing, pathNFD) {
		t.Fatalf("hasStoredNumericLoudness should match normalised key")
	}
}
