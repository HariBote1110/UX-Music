package server

import (
	"testing"
)

func libSongs(paths ...string) []interface{} {
	out := make([]interface{}, 0, len(paths))
	for _, p := range paths {
		out = append(out, map[string]interface{}{"path": p})
	}
	return out
}

func TestPickRecentlyAdded_ReturnsLastNInReverseOrder(t *testing.T) {
	songs := libSongs("a", "b", "c", "d", "e")
	got := pickRecentlyAdded(songs, 3)
	if len(got) != 3 {
		t.Fatalf("len = %d, want 3", len(got))
	}
	first := got[0].(map[string]interface{})["path"]
	last := got[2].(map[string]interface{})["path"]
	if first != "e" || last != "c" {
		t.Fatalf("order wrong: first=%v last=%v", first, last)
	}
}

func TestPickRecentlyAdded_LibrarySmallerThanLimit(t *testing.T) {
	songs := libSongs("a", "b")
	got := pickRecentlyAdded(songs, 20)
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2", len(got))
	}
}

func TestPickRecentlyAdded_EmptyLibrary(t *testing.T) {
	got := pickRecentlyAdded(nil, 20)
	if len(got) != 0 {
		t.Fatalf("len = %d, want 0", len(got))
	}
}

func TestPickMostPlayed_SortsDescendingByCount(t *testing.T) {
	songs := libSongs("a", "b", "c")
	counts := map[string]interface{}{
		"a": map[string]interface{}{"count": float64(2)},
		"b": map[string]interface{}{"count": float64(5)},
		"c": map[string]interface{}{"count": float64(1)},
	}
	got := pickMostPlayed(songs, counts, 10)
	if len(got) != 3 {
		t.Fatalf("len = %d, want 3", len(got))
	}
	if got[0].(map[string]interface{})["path"] != "b" {
		t.Fatalf("expected 'b' first, got %v", got[0])
	}
	if got[2].(map[string]interface{})["path"] != "c" {
		t.Fatalf("expected 'c' last, got %v", got[2])
	}
}

func TestPickMostPlayed_ExcludesZeroAndMissing(t *testing.T) {
	songs := libSongs("a", "b", "c")
	counts := map[string]interface{}{
		"a": map[string]interface{}{"count": float64(0)},
		"b": map[string]interface{}{"count": float64(3)},
	}
	got := pickMostPlayed(songs, counts, 10)
	if len(got) != 1 {
		t.Fatalf("len = %d, want 1 (only b)", len(got))
	}
	if got[0].(map[string]interface{})["path"] != "b" {
		t.Fatalf("expected 'b', got %v", got[0])
	}
}

func TestPickMostPlayed_LimitCaps(t *testing.T) {
	songs := libSongs("a", "b", "c", "d")
	counts := map[string]interface{}{
		"a": map[string]interface{}{"count": float64(1)},
		"b": map[string]interface{}{"count": float64(2)},
		"c": map[string]interface{}{"count": float64(3)},
		"d": map[string]interface{}{"count": float64(4)},
	}
	got := pickMostPlayed(songs, counts, 2)
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2", len(got))
	}
	if got[0].(map[string]interface{})["path"] != "d" || got[1].(map[string]interface{})["path"] != "c" {
		t.Fatalf("expected top 2 d,c, got %v", got)
	}
}

func TestPickRandomPick_StridesAcrossLibrary(t *testing.T) {
	songs := libSongs("a", "b", "c", "d", "e", "f", "g", "h", "i", "j")
	got := pickRandomPick(songs, 5)
	if len(got) != 5 {
		t.Fatalf("len = %d, want 5", len(got))
	}
	// Striding with step = len/limit = 2 picks indices 0, 2, 4, 6, 8.
	wantPaths := []string{"a", "c", "e", "g", "i"}
	for i, w := range wantPaths {
		if got[i].(map[string]interface{})["path"] != w {
			t.Fatalf("idx %d: got %v want %s", i, got[i], w)
		}
	}
}

func TestPickRandomPick_ReturnsEmptyForSmallLibrary(t *testing.T) {
	songs := libSongs("a", "b", "c")
	got := pickRandomPick(songs, 5)
	if len(got) != 0 {
		t.Fatalf("len = %d, want 0", len(got))
	}
}

// TestGenerateSituationPlaylists_OrderAndOmitsEmpty は、Wails 版 GetSituationPlaylists
// と LAN API ハンドラの両方が使う共有ロジックが、固定順序（最近追加→よく聴く→ランダム
// ピック）で空バケットを省いて返すことを検証する。
func TestGenerateSituationPlaylists_OrderAndOmitsEmpty(t *testing.T) {
	songs := libSongs("a", "b", "c")
	counts := map[string]interface{}{
		"b": map[string]interface{}{"count": float64(3)},
	}
	got := generateSituationPlaylists(songs, counts)

	// library has only 3 songs (< 5), so random pick is empty and must be omitted.
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2 (recently_added, most_played); got %+v", len(got), got)
	}
	if got[0].key != "recently_added" || got[0].name != "最近追加した曲" {
		t.Fatalf("bucket[0] = %+v, want recently_added", got[0])
	}
	if got[1].key != "most_played" || got[1].name != "よく聴く曲" {
		t.Fatalf("bucket[1] = %+v, want most_played", got[1])
	}
}

func TestGenerateSituationPlaylists_EmptyLibraryYieldsNoBuckets(t *testing.T) {
	got := generateSituationPlaylists(nil, nil)
	if len(got) != 0 {
		t.Fatalf("len = %d, want 0", len(got))
	}
}
