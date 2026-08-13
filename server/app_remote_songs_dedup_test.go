package server

import "testing"

func TestDedupRemoteSongs_UUIDBeatsPathLikeID(t *testing.T) {
	songs := []map[string]interface{}{
		{"id": "/Users/yuki/doc/uxmusic/CD Rips/Artist/09 - X.flac", "title": "X", "album": "A", "artist": "Artist", "trackNumber": 9, "discNumber": 1},
		{"id": "11111111-1111-1111-1111-111111111111", "title": "X", "album": "A", "artist": "Artist", "trackNumber": 9, "discNumber": 1},
	}
	got := dedupRemoteSongs(songs)
	if len(got) != 1 {
		t.Fatalf("want 1, got %d: %+v", len(got), got)
	}
	if remoteStringField(got[0], "id") != "11111111-1111-1111-1111-111111111111" {
		t.Fatalf("want UUID entry kept, got %+v", got[0])
	}
}

func TestDedupRemoteSongs_Disc0TreatedAsDisc1(t *testing.T) {
	songs := []map[string]interface{}{
		{"id": "11111111-1111-1111-1111-111111111111", "title": "X", "album": "A", "artist": "Artist", "trackNumber": 9, "discNumber": 0},
		{"id": "22222222-2222-2222-2222-222222222222", "title": "X", "album": "A", "artist": "Artist", "trackNumber": 9, "discNumber": 1, "fileSize": float64(100)},
	}
	got := dedupRemoteSongs(songs)
	if len(got) != 1 {
		t.Fatalf("want 1, got %d: %+v", len(got), got)
	}
}

func TestDedupRemoteSongs_GenuineMultiDiscKeepsBoth(t *testing.T) {
	songs := []map[string]interface{}{
		{"id": "11111111-1111-1111-1111-111111111111", "title": "X", "album": "A", "artist": "Artist", "trackNumber": 9, "discNumber": 1},
		{"id": "22222222-2222-2222-2222-222222222222", "title": "X", "album": "A", "artist": "Artist", "trackNumber": 9, "discNumber": 2},
	}
	got := dedupRemoteSongs(songs)
	if len(got) != 2 {
		t.Fatalf("want 2, got %d: %+v", len(got), got)
	}
}

func TestDedupRemoteSongs_DifferentTrackNumberKeepsBoth(t *testing.T) {
	songs := []map[string]interface{}{
		{"id": "11111111-1111-1111-1111-111111111111", "title": "X", "album": "A", "artist": "Artist", "trackNumber": 1, "discNumber": 1},
		{"id": "22222222-2222-2222-2222-222222222222", "title": "X", "album": "A", "artist": "Artist", "trackNumber": 2, "discNumber": 1},
	}
	got := dedupRemoteSongs(songs)
	if len(got) != 2 {
		t.Fatalf("want 2, got %d: %+v", len(got), got)
	}
}

func TestDedupRemoteSongs_TitleCaseAndWhitespaceIgnored(t *testing.T) {
	songs := []map[string]interface{}{
		{"id": "11111111-1111-1111-1111-111111111111", "title": "  X Song ", "album": "A", "artist": "Artist", "trackNumber": 1, "discNumber": 1},
		{"id": "22222222-2222-2222-2222-222222222222", "title": "x song", "album": "A", "artist": "Artist", "trackNumber": 1, "discNumber": 1},
	}
	got := dedupRemoteSongs(songs)
	if len(got) != 1 {
		t.Fatalf("want 1, got %d: %+v", len(got), got)
	}
}

func TestDedupRemoteSongs_YouTubeEntriesUntouched(t *testing.T) {
	songs := []map[string]interface{}{
		{"id": "yt-1", "title": "X", "album": "A", "artist": "Artist", "trackNumber": 1, "discNumber": 1, "type": "youtube"},
		{"id": "yt-2", "title": "X", "album": "A", "artist": "Artist", "trackNumber": 1, "discNumber": 1, "type": "youtube"},
	}
	got := dedupRemoteSongs(songs)
	if len(got) != 2 {
		t.Fatalf("want 2 (youtube entries not deduped), got %d: %+v", len(got), got)
	}
}

func TestDedupRemoteSongs_BothUUIDKeepsLargerFileSize(t *testing.T) {
	songs := []map[string]interface{}{
		{"id": "11111111-1111-1111-1111-111111111111", "title": "X", "album": "A", "artist": "Artist", "trackNumber": 1, "discNumber": 1, "fileSize": float64(50)},
		{"id": "22222222-2222-2222-2222-222222222222", "title": "X", "album": "A", "artist": "Artist", "trackNumber": 1, "discNumber": 1, "fileSize": float64(100)},
	}
	got := dedupRemoteSongs(songs)
	if len(got) != 1 {
		t.Fatalf("want 1, got %d: %+v", len(got), got)
	}
	if remoteStringField(got[0], "id") != "22222222-2222-2222-2222-222222222222" {
		t.Fatalf("want larger fileSize entry kept, got %+v", got[0])
	}
}

func TestDedupRemoteSongs_BothUUIDEqualFileSizeKeepsFirst(t *testing.T) {
	songs := []map[string]interface{}{
		{"id": "11111111-1111-1111-1111-111111111111", "title": "X", "album": "A", "artist": "Artist", "trackNumber": 1, "discNumber": 1, "fileSize": float64(50)},
		{"id": "22222222-2222-2222-2222-222222222222", "title": "X", "album": "A", "artist": "Artist", "trackNumber": 1, "discNumber": 1, "fileSize": float64(50)},
	}
	got := dedupRemoteSongs(songs)
	if len(got) != 1 {
		t.Fatalf("want 1, got %d: %+v", len(got), got)
	}
	if remoteStringField(got[0], "id") != "11111111-1111-1111-1111-111111111111" {
		t.Fatalf("want first entry kept on tie, got %+v", got[0])
	}
}

func TestDedupRemoteSongs_PreservesOriginalOrder(t *testing.T) {
	songs := []map[string]interface{}{
		{"id": "aaaa", "title": "Zeta", "album": "A", "artist": "Artist", "trackNumber": 1, "discNumber": 1},
		{"id": "bbbb", "title": "X", "album": "A", "artist": "Artist", "trackNumber": 2, "discNumber": 1},
		{"id": "cccc", "title": "X", "album": "A", "artist": "Artist", "trackNumber": 2, "discNumber": 1, "fileSize": float64(1)},
	}
	got := dedupRemoteSongs(songs)
	if len(got) != 2 {
		t.Fatalf("want 2, got %d: %+v", len(got), got)
	}
	if remoteStringField(got[0], "id") != "aaaa" {
		t.Fatalf("want original order preserved, first=%+v", got[0])
	}
}
