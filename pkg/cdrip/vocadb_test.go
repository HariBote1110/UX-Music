package cdrip

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// ─── テスト用スタブレスポンス ─────────────────────────────────────────────────

var stubAlbumSearchResponse = `{
  "items": [
    {
      "id": 1001,
      "name": "Re:Start",
      "artistString": "doriko feat. 初音ミク",
      "mainPicture": {
        "urlOriginal": "https://static.vocadb.net/img/album/1001.jpg",
        "urlSmallThumb": "https://static.vocadb.net/img/album/1001-s.jpg"
      }
    },
    {
      "id": 1002,
      "name": "Re:Make",
      "artistString": "ryo feat. 初音ミク",
      "mainPicture": null
    }
  ],
  "totalCount": 2
}`

var stubAlbumDetailResponse = `{
  "id": 1001,
  "name": "Re:Start",
  "artistString": "doriko feat. 初音ミク",
  "releaseDate": {
    "year": 2009,
    "month": 12,
    "day": 30
  },
  "mainPicture": {
    "urlOriginal": "https://static.vocadb.net/img/album/1001.jpg"
  },
  "tracks": [
    {
      "trackNumber": 1,
      "discNumber": 1,
      "song": {
        "id": 5001,
        "name": "Romeo and Cinderella",
        "artistString": "doriko feat. 初音ミク"
      }
    },
    {
      "trackNumber": 2,
      "discNumber": 1,
      "song": {
        "id": 5002,
        "name": "ロミオとシンデレラ -Arrange-",
        "artistString": "doriko feat. 初音ミク"
      }
    }
  ]
}`

// ─── SearchVocaDBByText ───────────────────────────────────────────────────────

func TestSearchVocaDBByText_ReturnsCandidates(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/albums" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(stubAlbumSearchResponse))
	}))
	defer srv.Close()

	releases, err := searchVocaDBByText(srv.URL, "Re:Start")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(releases) != 2 {
		t.Fatalf("expected 2 results, got %d", len(releases))
	}

	if releases[0].ID != "vocadb:1001" {
		t.Errorf("expected ID 'vocadb:1001', got %q", releases[0].ID)
	}
	if releases[0].Title != "Re:Start" {
		t.Errorf("expected title 'Re:Start', got %q", releases[0].Title)
	}
	if releases[0].Artist != "doriko feat. 初音ミク" {
		t.Errorf("expected artist 'doriko feat. 初音ミク', got %q", releases[0].Artist)
	}
	if releases[0].Artwork == "" {
		t.Error("expected artwork URL, got empty string")
	}
}

func TestSearchVocaDBByText_EmptyQuery_ReturnsError(t *testing.T) {
	_, err := searchVocaDBByText("https://vocadb.net", "")
	if err == nil {
		t.Error("expected error for empty query, got nil")
	}
}

func TestSearchVocaDBByText_NoResults_ReturnsEmptySlice(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"items": [], "totalCount": 0}`))
	}))
	defer srv.Close()

	releases, err := searchVocaDBByText(srv.URL, "存在しないアルバム")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(releases) != 0 {
		t.Errorf("expected 0 results, got %d", len(releases))
	}
}

// ─── ApplyVocaDBMetadata ──────────────────────────────────────────────────────

func TestApplyVocaDBMetadata_MergesTracks(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/albums/1001" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(stubAlbumDetailResponse))
	}))
	defer srv.Close()

	inputTracks := []Track{
		{Number: 1, Sectors: 19213},
		{Number: 2, Sectors: 16500},
	}

	result, err := applyVocaDBMetadata(srv.URL, inputTracks, "1001")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if result.Title != "Re:Start" {
		t.Errorf("expected album 'Re:Start', got %q", result.Title)
	}
	if result.Artist != "doriko feat. 初音ミク" {
		t.Errorf("expected artist 'doriko feat. 初音ミク', got %q", result.Artist)
	}
	if result.Artwork == "" {
		t.Error("expected artwork URL, got empty string")
	}
	if len(result.Tracks) != 2 {
		t.Fatalf("expected 2 tracks, got %d", len(result.Tracks))
	}
	if result.Tracks[0].Title != "Romeo and Cinderella" {
		t.Errorf("track 1 title: expected 'Romeo and Cinderella', got %q", result.Tracks[0].Title)
	}
	if result.Tracks[1].Title != "ロミオとシンデレラ -Arrange-" {
		t.Errorf("track 2 title: expected 'ロミオとシンデレラ -Arrange-', got %q", result.Tracks[1].Title)
	}
}

func TestApplyVocaDBMetadata_MoreCDTracksThanDB_FallsBackToAlbumArtist(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(stubAlbumDetailResponse)) // 2 トラックのレスポンス
	}))
	defer srv.Close()

	// CD には 3 トラックあるが VocaDB には 2 トラックしかない
	inputTracks := []Track{
		{Number: 1, Sectors: 19213},
		{Number: 2, Sectors: 16500},
		{Number: 3, Sectors: 12000},
	}

	result, err := applyVocaDBMetadata(srv.URL, inputTracks, "1001")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// トラック 3 はアルバムアーティストにフォールバックされること
	if result.Tracks[2].Artist != "doriko feat. 初音ミク" {
		t.Errorf("fallback track artist: expected 'doriko feat. 初音ミク', got %q", result.Tracks[2].Artist)
	}
	if result.Tracks[2].Album != "Re:Start" {
		t.Errorf("fallback track album: expected 'Re:Start', got %q", result.Tracks[2].Album)
	}
}

// ─── convertVocaDBID ─────────────────────────────────────────────────────────

func TestConvertVocaDBID_ValidID(t *testing.T) {
	id, err := parseVocaDBReleaseID("vocadb:1001")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if id != 1001 {
		t.Errorf("expected 1001, got %d", id)
	}
}

func TestConvertVocaDBID_InvalidFormat_ReturnsError(t *testing.T) {
	_, err := parseVocaDBReleaseID("1001") // プレフィックスなし
	if err == nil {
		t.Error("expected error for ID without 'vocadb:' prefix, got nil")
	}
}

func TestConvertVocaDBID_NonNumeric_ReturnsError(t *testing.T) {
	_, err := parseVocaDBReleaseID("vocadb:abc")
	if err == nil {
		t.Error("expected error for non-numeric ID, got nil")
	}
}

// ─── JSON 構造確認 ────────────────────────────────────────────────────────────

func TestVocaDBAlbumJSON_Unmarshal(t *testing.T) {
	var resp vocaDBAlbumSearchResponse
	if err := json.Unmarshal([]byte(stubAlbumSearchResponse), &resp); err != nil {
		t.Fatalf("failed to unmarshal album search response: %v", err)
	}
	if len(resp.Items) != 2 {
		t.Errorf("expected 2 items, got %d", len(resp.Items))
	}
	if resp.Items[0].ID != 1001 {
		t.Errorf("expected ID 1001, got %d", resp.Items[0].ID)
	}
}

func TestVocaDBAlbumDetailJSON_Unmarshal(t *testing.T) {
	var detail vocaDBAlbumDetail
	if err := json.Unmarshal([]byte(stubAlbumDetailResponse), &detail); err != nil {
		t.Fatalf("failed to unmarshal album detail response: %v", err)
	}
	if len(detail.Tracks) != 2 {
		t.Errorf("expected 2 tracks, got %d", len(detail.Tracks))
	}
	if detail.Tracks[0].Song.Name != "Romeo and Cinderella" {
		t.Errorf("unexpected track name: %q", detail.Tracks[0].Song.Name)
	}
}
