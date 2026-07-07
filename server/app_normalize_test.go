package server

import (
	"reflect"
	"testing"

	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/store"

	"golang.org/x/text/unicode/norm"
)

func useTempStore(t *testing.T) {
	t.Helper()
	prev := config.GetUserDataPath()
	config.SetUserDataPath(t.TempDir())
	if err := store.Instance.Save("loudness", map[string]interface{}{}); err != nil {
		t.Fatalf("failed to reset loudness store: %v", err)
	}
	t.Cleanup(func() {
		_ = store.Instance.Save("loudness", map[string]interface{}{})
		config.SetUserDataPath(prev)
	})
}

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
		{name: "map with loudness", value: map[string]interface{}{"loudness": float64(-14.0), "truePeak": float64(-1.2)}, want: true},
		{name: "map without loudness", value: map[string]interface{}{"truePeak": float64(-1.2)}, want: false},
		{name: "empty map", value: map[string]interface{}{}, want: false},
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
	pathNFD := "/Users/yuki/Music/バンド/曲.flac"
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
	pathNFD := "/Users/yuki/Music/バンド/曲.flac"
	pathNFC := norm.NFC.String(pathNFD)

	t.Run("legacy float64 format", func(t *testing.T) {
		existing := map[string]interface{}{
			pathNFC: float64(-9.5),
		}
		if !hasStoredNumericLoudness(existing, pathNFD) {
			t.Fatalf("hasStoredNumericLoudness should match normalised key")
		}
	})

	t.Run("current map format", func(t *testing.T) {
		existing := map[string]interface{}{
			pathNFC: map[string]interface{}{"loudness": float64(-9.5), "truePeak": float64(-1.0)},
		}
		if !hasStoredNumericLoudness(existing, pathNFD) {
			t.Fatalf("hasStoredNumericLoudness should match normalised key in map format")
		}
	})
}

func TestExtractLoudnessEntry(t *testing.T) {
	t.Run("legacy float64", func(t *testing.T) {
		l, tp, hasTp, ok := extractLoudnessEntry(float64(-14.0))
		if !ok || l != -14.0 || hasTp || tp != 0 {
			t.Fatalf("unexpected: ok=%v l=%v tp=%v hasTp=%v", ok, l, tp, hasTp)
		}
	})
	t.Run("map with truePeak", func(t *testing.T) {
		l, tp, hasTp, ok := extractLoudnessEntry(map[string]interface{}{"loudness": float64(-14.0), "truePeak": float64(-1.2)})
		if !ok || l != -14.0 || !hasTp || tp != -1.2 {
			t.Fatalf("unexpected: ok=%v l=%v tp=%v hasTp=%v", ok, l, tp, hasTp)
		}
	})
	t.Run("map without loudness key", func(t *testing.T) {
		_, _, _, ok := extractLoudnessEntry(map[string]interface{}{"truePeak": float64(-1.2)})
		if ok {
			t.Fatal("expected ok=false when loudness key missing")
		}
	})
	t.Run("nil", func(t *testing.T) {
		_, _, _, ok := extractLoudnessEntry(nil)
		if ok {
			t.Fatal("expected ok=false for nil")
		}
	})
}

func TestPendingLoudnessVisibleBeforeFlush(t *testing.T) {
	useTempStore(t)
	app := &App{}
	path := "/music/pending.flac"

	app.saveLoudnessEntry(path, -12.5, -1.2)
	t.Cleanup(app.flushPendingLoudness)

	got, err := app.GetLoudnessValue(path)
	if err != nil {
		t.Fatalf("GetLoudnessValue error: %v", err)
	}
	if got != float64(-12.5) {
		t.Fatalf("GetLoudnessValue = %#v, want -12.5", got)
	}

	all, err := app.GetAllLoudnessData()
	if err != nil {
		t.Fatalf("GetAllLoudnessData error: %v", err)
	}
	if !hasStoredNumericLoudness(all, path) {
		t.Fatalf("pending loudness should be visible in all data")
	}
}

func TestFlushPendingLoudnessWritesBatch(t *testing.T) {
	useTempStore(t)
	app := &App{}
	pathA := "/music/a.flac"
	pathB := "/music/b.flac"

	app.saveLoudnessEntry(pathA, -14.0, -1.0)
	app.saveLoudnessEntry(pathB, -10.0, -0.5)
	app.flushPendingLoudness()

	persisted := loadLoudnessMap()
	if !hasStoredNumericLoudness(persisted, pathA) {
		t.Fatalf("pathA loudness was not persisted")
	}
	if !hasStoredNumericLoudness(persisted, pathB) {
		t.Fatalf("pathB loudness was not persisted")
	}
	if len(app.loudnessPending) != 0 {
		t.Fatalf("pending len = %d, want 0", len(app.loudnessPending))
	}
}
