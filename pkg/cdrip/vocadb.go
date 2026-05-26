package cdrip

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

const (
	vocaDBBaseURL = "https://vocadb.net"
	vocaDBIDPrefix = "vocadb:"
)

// ─── VocaDB API レスポンス構造体 ──────────────────────────────────────────────

type vocaDBPicture struct {
	URLOriginal   string `json:"urlOriginal"`
	URLSmallThumb string `json:"urlSmallThumb"`
}

type vocaDBAlbumSummary struct {
	ID           int            `json:"id"`
	Name         string         `json:"name"`
	ArtistString string         `json:"artistString"`
	MainPicture  *vocaDBPicture `json:"mainPicture"`
}

type vocaDBAlbumSearchResponse struct {
	Items      []vocaDBAlbumSummary `json:"items"`
	TotalCount int                  `json:"totalCount"`
}

type vocaDBSong struct {
	ID           int    `json:"id"`
	Name         string `json:"name"`
	ArtistString string `json:"artistString"`
}

type vocaDBTrack struct {
	TrackNumber int        `json:"trackNumber"`
	DiscNumber  int        `json:"discNumber"`
	Song        vocaDBSong `json:"song"`
}

type vocaDBAlbumDetail struct {
	ID           int            `json:"id"`
	Name         string         `json:"name"`
	ArtistString string         `json:"artistString"`
	MainPicture  *vocaDBPicture `json:"mainPicture"`
	Tracks       []vocaDBTrack  `json:"tracks"`
}

// ─── HTTP クライアント ────────────────────────────────────────────────────────

func queryVocaDB(baseURL, path string, params url.Values) (json.RawMessage, error) {
	client := &http.Client{Timeout: 30 * time.Second}

	reqURL := fmt.Sprintf("%s%s?%s", baseURL, path, params.Encode())
	req, err := http.NewRequest("GET", reqURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Accept", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == 404 {
		return nil, nil
	}
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("VocaDB API returned status: %d", resp.StatusCode)
	}

	var data json.RawMessage
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return nil, err
	}
	return data, nil
}

// ─── ID ユーティリティ ────────────────────────────────────────────────────────

// parseVocaDBReleaseID は "vocadb:1001" 形式の文字列を整数 ID に変換する。
func parseVocaDBReleaseID(id string) (int, error) {
	if !strings.HasPrefix(id, vocaDBIDPrefix) {
		return 0, fmt.Errorf("VocaDB ID must start with %q: got %q", vocaDBIDPrefix, id)
	}
	numStr := strings.TrimPrefix(id, vocaDBIDPrefix)
	num, err := strconv.Atoi(numStr)
	if err != nil {
		return 0, fmt.Errorf("invalid VocaDB ID number %q: %w", numStr, err)
	}
	return num, nil
}

// IsVocaDBReleaseID は与えられた ID が VocaDB 形式かどうかを返す。
func IsVocaDBReleaseID(id string) bool {
	return strings.HasPrefix(id, vocaDBIDPrefix)
}

// ─── テスト可能な内部実装（baseURL を差し込める） ────────────────────────────

func searchVocaDBByText(baseURL, query string) ([]ReleaseInfo, error) {
	if strings.TrimSpace(query) == "" {
		return nil, fmt.Errorf("search query must not be empty")
	}

	params := url.Values{}
	params.Set("query", query)
	params.Set("maxResults", "15")
	params.Set("fields", "artists,mainPicture")
	params.Set("lang", "Japanese")

	data, err := queryVocaDB(baseURL, "/api/albums", params)
	if err != nil {
		return nil, err
	}
	if data == nil {
		return []ReleaseInfo{}, nil
	}

	var resp vocaDBAlbumSearchResponse
	if err := json.Unmarshal(data, &resp); err != nil {
		return nil, err
	}

	results := make([]ReleaseInfo, 0, len(resp.Items))
	for _, item := range resp.Items {
		artwork := ""
		if item.MainPicture != nil {
			artwork = item.MainPicture.URLOriginal
		}
		results = append(results, ReleaseInfo{
			ID:      fmt.Sprintf("%s%d", vocaDBIDPrefix, item.ID),
			Title:   item.Name,
			Artist:  item.ArtistString,
			Artwork: artwork,
		})
	}
	return results, nil
}

func applyVocaDBMetadata(baseURL string, tracks []Track, releaseID string) (*ReleaseInfo, error) {
	albumID, err := parseVocaDBReleaseID(releaseID)
	if err != nil {
		// 数値のみで渡された場合もサポート（後方互換）
		albumID, err = strconv.Atoi(releaseID)
		if err != nil {
			return nil, fmt.Errorf("invalid VocaDB release ID: %q", releaseID)
		}
	}

	params := url.Values{}
	params.Set("fields", "artists,mainPicture,tracks")
	params.Set("lang", "Japanese")

	data, err := queryVocaDB(baseURL, fmt.Sprintf("/api/albums/%d", albumID), params)
	if err != nil {
		return nil, err
	}
	if data == nil {
		return nil, fmt.Errorf("VocaDB album %d not found", albumID)
	}

	var detail vocaDBAlbumDetail
	if err := json.Unmarshal(data, &detail); err != nil {
		return nil, err
	}

	artwork := ""
	if detail.MainPicture != nil {
		artwork = detail.MainPicture.URLOriginal
	}

	// VocaDB のトラックをトラック番号でインデックス化（ディスク 1 優先）
	dbTrackMap := make(map[int]vocaDBTrack)
	for _, t := range detail.Tracks {
		disc := t.DiscNumber
		if disc == 0 {
			disc = 1
		}
		if disc == 1 {
			dbTrackMap[t.TrackNumber] = t
		}
	}

	resultTracks := make([]Track, len(tracks))
	copy(resultTracks, tracks)

	for i := range resultTracks {
		num := resultTracks[i].Number
		resultTracks[i].Album = detail.Name

		if dbTrack, ok := dbTrackMap[num]; ok {
			resultTracks[i].Title = dbTrack.Song.Name
			resultTracks[i].Artist = dbTrack.Song.ArtistString
		} else {
			// DB にないトラックはアルバムアーティストを適用
			if resultTracks[i].Artist == "" {
				resultTracks[i].Artist = detail.ArtistString
			}
		}
	}

	return &ReleaseInfo{
		ID:      fmt.Sprintf("%s%d", vocaDBIDPrefix, detail.ID),
		Title:   detail.Name,
		Artist:  detail.ArtistString,
		Tracks:  resultTracks,
		Artwork: artwork,
	}, nil
}

// ─── 公開 API（本番用 baseURL を使用） ───────────────────────────────────────

// SearchVocaDBByText はテキストクエリで VocaDB のアルバムを検索する。
func SearchVocaDBByText(query string) ([]ReleaseInfo, error) {
	return searchVocaDBByText(vocaDBBaseURL, query)
}

// ApplyVocaDBMetadata は VocaDB のアルバム ID からメタデータを取得してトラックに適用する。
func ApplyVocaDBMetadata(tracks []Track, releaseID string) (*ReleaseInfo, error) {
	return applyVocaDBMetadata(vocaDBBaseURL, tracks, releaseID)
}
