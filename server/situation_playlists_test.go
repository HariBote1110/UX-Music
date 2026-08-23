package server

import (
	"testing"
	"time"
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

// TestPickRandomPick_ReturnsEmptyForSingleSongLibrary は、ライブラリの gate が
// 「5曲以上」から「2曲以上」に緩和されたことを検証する（1曲では意味がないため
// 引き続き空を返す）。
func TestPickRandomPick_ReturnsEmptyForSingleSongLibrary(t *testing.T) {
	songs := libSongs("a")
	got := pickRandomPick(songs, 5)
	if len(got) != 0 {
		t.Fatalf("len = %d, want 0", len(got))
	}
}

func TestPickRandomPick_WorksWithTwoSongs(t *testing.T) {
	songs := libSongs("a", "b")
	got := pickRandomPick(songs, 5)
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2; got %v", len(got), got)
	}
}

func TestLastPlayedByPath_ParsesLatestHistoryEntry(t *testing.T) {
	counts := map[string]interface{}{
		"/x/a.flac": map[string]interface{}{
			"count": float64(3),
			"history": []interface{}{
				"2026-01-01T00:00:00Z",
				"2026-06-15T12:00:00Z",
				"2026-03-01T00:00:00Z",
			},
		},
		"/x/b.flac": map[string]interface{}{"count": float64(1)}, // no history
	}
	got := lastPlayedByPath(counts)
	want := time.Date(2026, 6, 15, 12, 0, 0, 0, time.UTC)
	if !got["/x/a.flac"].Equal(want) {
		t.Fatalf("a lastPlayed = %v, want %v", got["/x/a.flac"], want)
	}
	if _, ok := got["/x/b.flac"]; ok {
		t.Fatalf("b should have no lastPlayed entry (no history)")
	}
}

func TestPickRediscover_IncludesStaleHighCountSongs(t *testing.T) {
	now := time.Date(2026, 8, 23, 0, 0, 0, 0, time.UTC)
	songs := libSongs("stale", "fresh", "neverplayed")
	counts := map[string]interface{}{
		"stale": map[string]interface{}{
			"count":   float64(10),
			"history": []interface{}{now.Add(-60 * 24 * time.Hour).Format(time.RFC3339)},
		},
		"fresh": map[string]interface{}{
			"count":   float64(10),
			"history": []interface{}{now.Add(-1 * 24 * time.Hour).Format(time.RFC3339)},
		},
	}
	lastPlayed := lastPlayedByPath(counts)
	got := pickRediscover(songs, counts, lastPlayed, now, 20)
	if len(got) != 1 || got[0].(map[string]interface{})["path"] != "stale" {
		t.Fatalf("got %v, want only 'stale'", got)
	}
}

func TestPickRediscover_EmptyWithoutPlayCounts(t *testing.T) {
	now := time.Now()
	songs := libSongs("a", "b")
	got := pickRediscover(songs, nil, nil, now, 20)
	if len(got) != 0 {
		t.Fatalf("len = %d, want 0", len(got))
	}
}

func TestPickArtistSpotlight_PicksWeightedArtistDeterministically(t *testing.T) {
	songs := []interface{}{
		map[string]interface{}{"path": "a1", "artist": "Alice"},
		map[string]interface{}{"path": "a2", "artist": "Alice"},
		map[string]interface{}{"path": "b1", "artist": "Bob"},
	}
	counts := map[string]interface{}{
		"a1": map[string]interface{}{"count": float64(50)},
		"a2": map[string]interface{}{"count": float64(50)},
		"b1": map[string]interface{}{"count": float64(1)},
	}
	artist, got := pickArtistSpotlight(songs, counts, 1, 20)
	if artist != "Alice" {
		t.Fatalf("artist = %q, want Alice (dominant weight)", artist)
	}
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2 (Alice's songs)", len(got))
	}
}

func TestPickArtistSpotlight_EmptyWithoutPlayCounts(t *testing.T) {
	songs := []interface{}{
		map[string]interface{}{"path": "a1", "artist": "Alice"},
	}
	artist, got := pickArtistSpotlight(songs, nil, 1, 20)
	if artist != "" || len(got) != 0 {
		t.Fatalf("artist=%q got=%v, want empty", artist, got)
	}
}

func TestPickArtistSpotlight_SameSeedIsStable(t *testing.T) {
	songs := []interface{}{
		map[string]interface{}{"path": "a1", "artist": "Alice"},
		map[string]interface{}{"path": "b1", "artist": "Bob"},
	}
	counts := map[string]interface{}{
		"a1": map[string]interface{}{"count": float64(5)},
		"b1": map[string]interface{}{"count": float64(5)},
	}
	artist1, _ := pickArtistSpotlight(songs, counts, 42, 20)
	artist2, _ := pickArtistSpotlight(songs, counts, 42, 20)
	if artist1 != artist2 {
		t.Fatalf("same seed produced different artists: %q vs %q", artist1, artist2)
	}
}

func TestPickAlbumDeepCut_PrefersLeastPlayedInMostPlayedAlbum(t *testing.T) {
	songs := []interface{}{
		map[string]interface{}{"path": "hit1", "album": "Popular"},
		map[string]interface{}{"path": "deepcut", "album": "Popular"},
		map[string]interface{}{"path": "other", "album": "Unplayed"},
	}
	counts := map[string]interface{}{
		"hit1":    map[string]interface{}{"count": float64(20)},
		"deepcut": map[string]interface{}{"count": float64(1)},
	}
	got := pickAlbumDeepCut(songs, counts, 20)
	if len(got) != 2 {
		t.Fatalf("len = %d, want 2 (only songs from the played 'Popular' album); got %v", len(got), got)
	}
	if got[0].(map[string]interface{})["path"] != "deepcut" {
		t.Fatalf("expected least-played song first, got %v", got[0])
	}
}

func TestPickAlbumDeepCut_EmptyWithoutPlayCounts(t *testing.T) {
	songs := []interface{}{
		map[string]interface{}{"path": "a", "album": "X"},
	}
	got := pickAlbumDeepCut(songs, nil, 20)
	if len(got) != 0 {
		t.Fatalf("len = %d, want 0", len(got))
	}
}

func TestPickGenreOrDecadeMix_PrefersGenreWhenAvailable(t *testing.T) {
	songs := []interface{}{
		map[string]interface{}{"path": "a", "genre": "Rock", "year": float64(1990)},
		map[string]interface{}{"path": "b", "genre": "Rock", "year": float64(1991)},
		map[string]interface{}{"path": "c", "genre": "Jazz", "year": float64(1980)},
	}
	key, name, desc, got := pickGenreOrDecadeMix(songs, 0, 20)
	if key != "genre_mix" {
		t.Fatalf("key = %q, want genre_mix", key)
	}
	if name == "" || desc == "" {
		t.Fatalf("expected non-empty name/description")
	}
	if len(got) == 0 {
		t.Fatalf("expected non-empty song list")
	}
}

func TestPickGenreOrDecadeMix_FallsBackToDecadeWithoutGenre(t *testing.T) {
	songs := []interface{}{
		map[string]interface{}{"path": "a", "year": float64(1995)},
		map[string]interface{}{"path": "b", "year": float64(1996)},
	}
	key, _, _, got := pickGenreOrDecadeMix(songs, 0, 20)
	if key != "decade_mix" {
		t.Fatalf("key = %q, want decade_mix", key)
	}
	for _, s := range got {
		if s.(map[string]interface{})["path"] != "a" && s.(map[string]interface{})["path"] != "b" {
			t.Fatalf("unexpected song in decade mix: %v", s)
		}
	}
}

func TestPickGenreOrDecadeMix_EmptyWithoutGenreOrYear(t *testing.T) {
	songs := libSongs("a", "b")
	key, name, desc, got := pickGenreOrDecadeMix(songs, 0, 20)
	if key != "" || name != "" || desc != "" || len(got) != 0 {
		t.Fatalf("expected all empty, got key=%q name=%q desc=%q songs=%v", key, name, desc, got)
	}
}

func TestDailySeed_StableWithinDayDiffersAcrossDays(t *testing.T) {
	d1 := time.Date(2026, 8, 23, 3, 0, 0, 0, time.UTC)
	d2 := time.Date(2026, 8, 23, 23, 0, 0, 0, time.UTC)
	d3 := time.Date(2026, 8, 24, 3, 0, 0, 0, time.UTC)
	if dailySeed(d1) != dailySeed(d2) {
		t.Fatalf("seed should be stable within the same day")
	}
	if dailySeed(d1) == dailySeed(d3) {
		t.Fatalf("seed should differ across days")
	}
}

// TestGenerateSituationPlaylists_OrderAndOmitsEmpty は、共有ロジックが固定順序
// （最近追加→よく聴く→ランダムピック→…）で、根拠のあるバケットのみを返すことを
// 検証する。曲に artist/album/genre/year が無いため、artist_spotlight・
// album_deep_cut・genre_mix・decade_mix は成立せず省かれる。
func TestGenerateSituationPlaylists_OrderAndOmitsEmpty(t *testing.T) {
	songs := libSongs("a", "b", "c")
	counts := map[string]interface{}{
		"b": map[string]interface{}{"count": float64(3)},
	}
	now := time.Date(2026, 8, 23, 0, 0, 0, 0, time.UTC)
	got := generateSituationPlaylists(songs, counts, now)

	wantKeys := []string{"recently_added", "most_played", "random_pick", "rediscover"}
	if len(got) != len(wantKeys) {
		t.Fatalf("len = %d, want %d; got %+v", len(got), len(wantKeys), got)
	}
	for i, k := range wantKeys {
		if got[i].key != k {
			t.Fatalf("bucket[%d].key = %q, want %q (full: %+v)", i, got[i].key, k, got)
		}
	}
	if got[0].name != "最近追加した曲" {
		t.Fatalf("bucket[0].name = %q", got[0].name)
	}
	if got[1].name != "よく聴く曲" {
		t.Fatalf("bucket[1].name = %q", got[1].name)
	}
	for _, b := range got {
		if b.description == "" {
			t.Fatalf("bucket %q has empty description", b.key)
		}
	}
}

func TestGenerateSituationPlaylists_EmptyLibraryYieldsNoBuckets(t *testing.T) {
	got := generateSituationPlaylists(nil, nil, time.Now())
	if len(got) != 0 {
		t.Fatalf("len = %d, want 0", len(got))
	}
}

// TestGenerateSituationPlaylists_MostPlayedFallsBackToRecentlyPlayed は、
// playcounts が全く無くても lastPlayed があれば「よく聴く曲」の代わりに
// 「最近再生した曲」で埋まることを検証する。
func TestGenerateSituationPlaylists_MostPlayedFallsBackToRecentlyPlayed(t *testing.T) {
	now := time.Date(2026, 8, 23, 0, 0, 0, 0, time.UTC)
	songs := libSongs("a", "b")
	counts := map[string]interface{}{
		"a": map[string]interface{}{
			"count":   float64(0),
			"history": []interface{}{now.Add(-2 * time.Hour).Format(time.RFC3339)},
		},
	}
	got := generateSituationPlaylists(songs, counts, now)
	found := false
	for _, b := range got {
		if b.key == "most_played" {
			found = true
			if b.name != "最近再生した曲" {
				t.Fatalf("fallback bucket name = %q, want 最近再生した曲", b.name)
			}
		}
	}
	if !found {
		t.Fatalf("expected most_played (fallback) bucket present; got %+v", got)
	}
}

// TestGenerateSituationPlaylists_ArtworksPopulatedFromSongs は、各バケットの
// artworks が collageArtworks 経由でアルバム重複排除つき最大4件で埋まることを
// 検証する。
func TestGenerateSituationPlaylists_ArtworksPopulatedFromSongs(t *testing.T) {
	songs := []interface{}{
		map[string]interface{}{"path": "a", "album": "Album A", "artwork": "a.webp"},
		map[string]interface{}{"path": "b", "album": "Album B", "artwork": "b.webp"},
	}
	now := time.Now()
	got := generateSituationPlaylists(songs, nil, now)
	if len(got) == 0 {
		t.Fatalf("expected at least recently_added bucket")
	}
	if len(got[0].artworks) != 2 {
		t.Fatalf("artworks = %v, want 2", got[0].artworks)
	}
}
