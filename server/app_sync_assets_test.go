package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/store"
)

var errTestSyncTranscodeFailed = errors.New("test sync transcode failed")

func TestSyncLibrarySnapshotRequiresTokenAndReturnsLibraryTracks(t *testing.T) {
	newTempSyncStore(t)
	token := ensureSyncAuthTokenForDevice("portable-client")
	songPath := filepath.Join(t.TempDir(), "song.flac")
	if err := store.Instance.Save("library", []map[string]interface{}{
		{
			"id":     "track-1",
			"path":   songPath,
			"title":  "Song",
			"artist": "Artist",
			"artwork": map[string]interface{}{
				"full": "large artwork payload is omitted",
			},
		},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}
	if err := store.Instance.Save("playcounts", map[string]interface{}{
		songPath: map[string]interface{}{
			"count":   12,
			"history": []interface{}{"2026-06-10T01:00:00Z"},
		},
	}); err != nil {
		t.Fatalf("seed playcounts: %v", err)
	}

	handler := NewLANHTTPHandler(NewApp())
	missing := httptest.NewRecorder()
	handler.ServeHTTP(missing, httptest.NewRequest(http.MethodGet, "/sync/library/snapshot", nil))
	if missing.Code != http.StatusUnauthorized {
		t.Fatalf("expected snapshot to require sync token, got %d", missing.Code)
	}

	req := httptest.NewRequest(http.MethodGet, "/sync/library/snapshot", nil)
	req.Header.Set("X-UX-Music-Sync-Token", token)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status %d: %s", rec.Code, rec.Body.String())
	}
	var response syncLibrarySnapshotResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.Count != 1 || len(response.Tracks) != 1 {
		t.Fatalf("unexpected snapshot count: %#v", response)
	}
	if _, exists := response.Tracks[0]["artwork"]; exists {
		t.Fatalf("snapshot should omit artwork blobs: %#v", response.Tracks[0])
	}
	playCount, _ := response.Tracks[0]["syncPlayCount"].(map[string]interface{})
	if playCount["count"] != float64(12) {
		t.Fatalf("snapshot should include playcount metadata, got %#v", response.Tracks[0])
	}
}

func TestSyncLibrarySnapshotDeduplicatesRepeatedLibraryPaths(t *testing.T) {
	newTempSyncStore(t)
	token := ensureSyncAuthTokenForDevice("portable-client")
	songPath := filepath.Join(t.TempDir(), "duplicated.mp3")
	if err := store.Instance.Save("library", []map[string]interface{}{
		{
			"id":                   "track-1",
			"path":                 songPath,
			"title":                "Duplicated",
			"artist":               "Artist",
			"syncSourceDeviceId":   "host-device",
			"syncSourceTrackId":    "source-track-1",
			"syncTransferEncoding": "mp3_320",
		},
		{
			"id":                   "track-2",
			"path":                 songPath,
			"title":                "Duplicated",
			"artist":               "Artist",
			"syncSourceDeviceId":   "host-device",
			"syncSourceTrackId":    "source-track-2",
			"syncTransferEncoding": "mp3_320",
		},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}
	if err := store.Instance.Save("playcounts", map[string]interface{}{
		songPath: map[string]interface{}{"count": 7},
	}); err != nil {
		t.Fatalf("seed playcounts: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/sync/library/snapshot", nil)
	req.Header.Set("X-UX-Music-Sync-Token", token)
	rec := httptest.NewRecorder()
	NewLANHTTPHandler(NewApp()).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status %d: %s", rec.Code, rec.Body.String())
	}
	var response syncLibrarySnapshotResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if response.Count != 1 || len(response.Tracks) != 1 {
		t.Fatalf("snapshot should deduplicate repeated paths, got count=%d tracks=%#v", response.Count, response.Tracks)
	}
	if response.Tracks[0]["id"] != "track-1" {
		t.Fatalf("snapshot should keep the first library entry as representative, got %#v", response.Tracks[0])
	}
	playCount, _ := response.Tracks[0]["syncPlayCount"].(map[string]interface{})
	if playCount["count"] != float64(7) {
		t.Fatalf("snapshot should keep playcount metadata on representative track, got %#v", response.Tracks[0])
	}
}

func TestSyncAssetFileServesOriginalFileByTrackID(t *testing.T) {
	newTempSyncStore(t)
	token := ensureSyncAuthTokenForDevice("portable-client")
	dir := t.TempDir()
	audioPath := filepath.Join(dir, "source.flac")
	if err := os.WriteFile(audioPath, []byte("audio-bytes"), 0o644); err != nil {
		t.Fatalf("seed audio: %v", err)
	}
	if err := store.Instance.Save("library", []map[string]interface{}{
		{"id": "track-1", "path": audioPath},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/sync/assets/track-1/file", nil)
	req.Header.Set("X-UX-Music-Sync-Token", token)
	rec := httptest.NewRecorder()
	NewLANHTTPHandler(NewApp()).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status %d: %s", rec.Code, rec.Body.String())
	}
	if got := rec.Body.String(); got != "audio-bytes" {
		t.Fatalf("unexpected file body %q", got)
	}
}

func TestSyncAssetFileServesMP3320EncodingWhenRequested(t *testing.T) {
	newTempSyncStore(t)
	token := ensureSyncAuthTokenForDevice("portable-client")
	dir := t.TempDir()
	audioPath := filepath.Join(dir, "source.flac")
	if err := os.WriteFile(audioPath, []byte("flac-bytes"), 0o644); err != nil {
		t.Fatalf("seed audio: %v", err)
	}
	if err := store.Instance.Save("library", []map[string]interface{}{
		{"id": "track-1", "path": audioPath, "fileType": ".flac"},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}
	var observedInput string
	originalOpen := syncOpenMP3Stream
	syncOpenMP3Stream = func(_ context.Context, inputPath string) (io.ReadCloser, func() error, error) {
		observedInput = inputPath
		return io.NopCloser(strings.NewReader("mp3-320-bytes")), func() error { return nil }, nil
	}
	t.Cleanup(func() { syncOpenMP3Stream = originalOpen })

	req := httptest.NewRequest(http.MethodGet, "/sync/assets/track-1/file?encoding=mp3_320", nil)
	req.Header.Set("X-UX-Music-Sync-Token", token)
	rec := httptest.NewRecorder()
	NewLANHTTPHandler(NewApp()).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status %d: %s", rec.Code, rec.Body.String())
	}
	if observedInput != audioPath {
		t.Fatalf("expected mp3 stream to open %q, got %q", audioPath, observedInput)
	}
	if rec.Header().Get("Content-Type") != "audio/mpeg" {
		t.Fatalf("expected audio/mpeg content type, got %q", rec.Header().Get("Content-Type"))
	}
	if rec.Header().Get("X-UX-Music-Sync-Transfer-Encoding") != syncTransferEncodingMP3320 || rec.Header().Get("X-UX-Music-Sync-Audio-Bitrate") != "320" {
		t.Fatalf("missing mp3 transfer headers: %#v", rec.Header())
	}
	if disposition := rec.Header().Get("Content-Disposition"); !strings.Contains(disposition, `filename="source.mp3"`) {
		t.Fatalf("expected mp3 filename in disposition, got %q", disposition)
	}
	if got := rec.Body.String(); got != "mp3-320-bytes" {
		t.Fatalf("unexpected mp3 body %q", got)
	}
}

func TestSyncAssetFileKeepsOriginalMP3WhenMP3320Requested(t *testing.T) {
	newTempSyncStore(t)
	token := ensureSyncAuthTokenForDevice("portable-client")
	dir := t.TempDir()
	audioPath := filepath.Join(dir, "source.mp3")
	if err := os.WriteFile(audioPath, []byte("original-mp3"), 0o644); err != nil {
		t.Fatalf("seed audio: %v", err)
	}
	if err := store.Instance.Save("library", []map[string]interface{}{
		{"id": "track-1", "path": audioPath, "fileType": ".mp3"},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}
	originalOpen := syncOpenMP3Stream
	syncOpenMP3Stream = func(_ context.Context, _ string) (io.ReadCloser, func() error, error) {
		t.Fatal("mp3 source should not be transcoded again")
		return nil, nil, nil
	}
	t.Cleanup(func() { syncOpenMP3Stream = originalOpen })

	req := httptest.NewRequest(http.MethodGet, "/sync/assets/track-1/file?encoding=mp3_320", nil)
	req.Header.Set("X-UX-Music-Sync-Token", token)
	rec := httptest.NewRecorder()
	NewLANHTTPHandler(NewApp()).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status %d: %s", rec.Code, rec.Body.String())
	}
	if rec.Body.String() != "original-mp3" {
		t.Fatalf("unexpected body %q", rec.Body.String())
	}
	if rec.Header().Get("X-UX-Music-Sync-Transfer-Encoding") != "" {
		t.Fatalf("original mp3 response should not mark transcode headers: %#v", rec.Header())
	}
}

func TestSyncAssetFileFailsMP3320EncodingWithoutOriginalFallback(t *testing.T) {
	newTempSyncStore(t)
	token := ensureSyncAuthTokenForDevice("portable-client")
	dir := t.TempDir()
	audioPath := filepath.Join(dir, "source.flac")
	if err := os.WriteFile(audioPath, []byte("flac-bytes"), 0o644); err != nil {
		t.Fatalf("seed audio: %v", err)
	}
	if err := store.Instance.Save("library", []map[string]interface{}{
		{"id": "track-1", "path": audioPath, "fileType": ".flac"},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}
	originalOpen := syncOpenMP3Stream
	syncOpenMP3Stream = func(_ context.Context, _ string) (io.ReadCloser, func() error, error) {
		return nil, nil, errTestSyncTranscodeFailed
	}
	t.Cleanup(func() { syncOpenMP3Stream = originalOpen })

	req := httptest.NewRequest(http.MethodGet, "/sync/assets/track-1/file?encoding=mp3_320", nil)
	req.Header.Set("X-UX-Music-Sync-Token", token)
	rec := httptest.NewRecorder()
	NewLANHTTPHandler(NewApp()).ServeHTTP(rec, req)

	if rec.Code < 500 || rec.Code >= 600 {
		t.Fatalf("expected transcode failure status, got %d body=%q", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "flac-bytes") {
		t.Fatalf("transcode failure should not fall back to original bytes")
	}
}

func TestSyncAssetArtworkServesArtworkByTrackID(t *testing.T) {
	newTempSyncStore(t)
	token := ensureSyncAuthTokenForDevice("portable-client")
	artworksDir := filepath.Join(config.GetUserDataPath(), "Artworks")
	if err := os.MkdirAll(artworksDir, 0o755); err != nil {
		t.Fatalf("create artworks dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(artworksDir, "cover.webp"), []byte("cover-bytes"), 0o644); err != nil {
		t.Fatalf("seed artwork: %v", err)
	}
	if err := store.Instance.Save("library", []map[string]interface{}{
		{"id": "track-1", "path": filepath.Join(t.TempDir(), "source.flac"), "artwork": map[string]interface{}{"full": "cover.webp"}},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/sync/assets/track-1/artwork", nil)
	req.Header.Set("X-UX-Music-Sync-Token", token)
	rec := httptest.NewRecorder()
	NewLANHTTPHandler(NewApp()).ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status %d: %s", rec.Code, rec.Body.String())
	}
	if got := rec.Body.String(); got != "cover-bytes" {
		t.Fatalf("unexpected artwork body %q", got)
	}
}

func TestSyncLibraryImportRequiresTokenAndImportsUploadedTrack(t *testing.T) {
	newTempSyncStore(t)
	token := ensureSyncAuthTokenForDevice("dev_mac_mini")

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	metadata, err := writer.CreateFormField("metadata")
	if err != nil {
		t.Fatalf("create metadata field: %v", err)
	}
	if err := json.NewEncoder(metadata).Encode(syncLibraryImportRequest{
		SourceDeviceID:    "dev_mac_mini",
		SourceDisplayName: "YukinoMac-mini",
		Track: map[string]interface{}{
			"id":          "track-1",
			"title":       "Song",
			"artist":      "Artist",
			"album":       "Album",
			"albumartist": "Artist",
			"fileType":    ".flac",
			"artwork":     map[string]interface{}{"full": "large artwork payload is omitted"},
		},
	}); err != nil {
		t.Fatalf("write metadata: %v", err)
	}
	file, err := writer.CreateFormFile("file", "source.flac")
	if err != nil {
		t.Fatalf("create file field: %v", err)
	}
	if _, err := file.Write([]byte("uploaded-audio")); err != nil {
		t.Fatalf("write file: %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close multipart: %v", err)
	}

	missing := httptest.NewRequest(http.MethodPost, "/sync/library/import", bytes.NewReader(body.Bytes()))
	missing.Header.Set("Content-Type", writer.FormDataContentType())
	missingRec := httptest.NewRecorder()
	NewLANHTTPHandler(NewApp()).ServeHTTP(missingRec, missing)
	if missingRec.Code != http.StatusUnauthorized {
		t.Fatalf("expected import to require sync token, got %d", missingRec.Code)
	}

	req := httptest.NewRequest(http.MethodPost, "/sync/library/import", bytes.NewReader(body.Bytes()))
	req.Header.Set("Content-Type", writer.FormDataContentType())
	req.Header.Set("X-UX-Music-Sync-Token", token)
	rec := httptest.NewRecorder()
	NewLANHTTPHandler(NewApp()).ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status %d: %s", rec.Code, rec.Body.String())
	}
	var response syncLibraryImportResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if !response.Imported || response.Skipped || response.Path == "" {
		t.Fatalf("unexpected import response: %#v", response)
	}
	bytes, err := os.ReadFile(response.Path)
	if err != nil {
		t.Fatalf("read imported file: %v", err)
	}
	if string(bytes) != "uploaded-audio" {
		t.Fatalf("unexpected uploaded bytes %q", string(bytes))
	}
	library, err := store.Instance.LoadSlice("library")
	if err != nil {
		t.Fatalf("load library: %v", err)
	}
	imported := library[0].(map[string]interface{})
	if imported["syncSourceDeviceId"] != "dev_mac_mini" || imported["syncSourceTrackId"] != "track-1" {
		t.Fatalf("missing source markers: %#v", imported)
	}
	if _, exists := imported["artwork"]; exists {
		t.Fatalf("import should omit artwork blobs: %#v", imported)
	}
}

func TestSyncLibraryImportUpdatesPlayCountWhenTrackAlreadyExists(t *testing.T) {
	newTempSyncStore(t)
	token := ensureSyncAuthTokenForDevice("dev_mac_mini")
	existingPath := filepath.Join(t.TempDir(), "already-imported.flac")
	if err := os.WriteFile(existingPath, []byte("existing-audio"), 0o644); err != nil {
		t.Fatalf("write existing file: %v", err)
	}
	if err := store.Instance.Save("library", []map[string]interface{}{
		{
			"id":                 "imported-track",
			"path":               existingPath,
			"title":              "Song",
			"syncSourceDeviceId": "dev_mac_mini",
			"syncSourceTrackId":  "track-1",
		},
	}); err != nil {
		t.Fatalf("save library: %v", err)
	}

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	metadata, err := writer.CreateFormField("metadata")
	if err != nil {
		t.Fatalf("create metadata field: %v", err)
	}
	if err := json.NewEncoder(metadata).Encode(syncLibraryImportRequest{
		SourceDeviceID:    "dev_mac_mini",
		SourceDisplayName: "YukinoMac-mini",
		Track: map[string]interface{}{
			"id":    "track-1",
			"title": "Song",
			"syncPlayCount": map[string]interface{}{
				"count": 24,
			},
		},
	}); err != nil {
		t.Fatalf("write metadata: %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close multipart: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/sync/library/import", bytes.NewReader(body.Bytes()))
	req.Header.Set("Content-Type", writer.FormDataContentType())
	req.Header.Set("X-UX-Music-Sync-Token", token)
	rec := httptest.NewRecorder()
	NewLANHTTPHandler(NewApp()).ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status %d: %s", rec.Code, rec.Body.String())
	}
	var response syncLibraryImportResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if !response.Skipped || response.Imported {
		t.Fatalf("expected skipped duplicate import, got %#v", response)
	}
	counts, err := store.Instance.LoadMap("playcounts")
	if err != nil {
		t.Fatalf("load playcounts: %v", err)
	}
	entry, _ := counts[existingPath].(map[string]interface{})
	if entry["count"] != float64(24) {
		t.Fatalf("expected existing imported track playcount to update, got %#v", counts)
	}
}

func TestPushSyncLibraryAssetsUploadsLocalTrackToRemotePeer(t *testing.T) {
	newTempSyncStore(t)
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey:   "dev_local_mac",
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_remote_pc": "tok_remote"},
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	dir := t.TempDir()
	audioPath := filepath.Join(dir, "local.flac")
	if err := os.WriteFile(audioPath, []byte("local-audio"), 0o644); err != nil {
		t.Fatalf("seed audio: %v", err)
	}
	if err := store.Instance.Save("library", []map[string]interface{}{
		{
			"id":          "local-track-1",
			"path":        audioPath,
			"title":       "Local Song",
			"artist":      "Artist",
			"album":       "Album",
			"albumartist": "Artist",
			"fileType":    ".flac",
		},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}

	observer := &handlerObserver{}
	var observedToken string
	var observedSourceDeviceID string
	var observedTrackID string
	var observedBytes string
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{DeviceID: "dev_remote_pc", DisplayName: "mainPC"})
		case "/sync/library/import":
			observedToken = r.Header.Get("X-UX-Music-Sync-Token")
			if err := r.ParseMultipartForm(32 << 20); err != nil {
				observer.errorf("parse multipart: %v", err)
				http.Error(w, "bad multipart", http.StatusBadRequest)
				return
			}
			var req syncLibraryImportRequest
			if err := json.Unmarshal([]byte(r.FormValue("metadata")), &req); err != nil {
				observer.errorf("decode metadata: %v", err)
				http.Error(w, "bad metadata", http.StatusBadRequest)
				return
			}
			observedSourceDeviceID = req.SourceDeviceID
			observedTrackID = syncTrackID(req.Track)
			file, _, err := r.FormFile("file")
			if err != nil {
				observer.errorf("read file part: %v", err)
				http.Error(w, "missing file part", http.StatusBadRequest)
				return
			}
			defer file.Close()
			payload, err := io.ReadAll(file)
			if err != nil {
				observer.errorf("read payload: %v", err)
				http.Error(w, "unreadable payload", http.StatusBadRequest)
				return
			}
			observedBytes = string(payload)
			writeJSON(w, syncLibraryImportResponse{Imported: true, Path: `C:\SyncLibrary\local.flac`})
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()

	result, err := NewApp().PushSyncLibraryAssets(remote.URL, 0)
	observer.assertNoErrors(t)
	if err != nil {
		t.Fatalf("PushSyncLibraryAssets: %v", err)
	}
	if result.Transferred != 1 || result.Skipped != 0 || result.Failed != 0 {
		t.Fatalf("unexpected push result: %#v", result)
	}
	if observedToken != "tok_remote" {
		t.Fatalf("expected saved token to be used, got %q", observedToken)
	}
	if observedSourceDeviceID != "dev_local_mac" || observedTrackID != "local-track-1" || observedBytes != "local-audio" {
		t.Fatalf("unexpected upload source=%q track=%q bytes=%q", observedSourceDeviceID, observedTrackID, observedBytes)
	}
}

func TestPushSyncLibraryAssetsIncludesMetadataArtworkAndPlayCount(t *testing.T) {
	newTempSyncStore(t)
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey:   "dev_local_mac",
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_remote_pc": "tok_remote"},
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	dir := t.TempDir()
	audioPath := filepath.Join(dir, "local.flac")
	if err := os.WriteFile(audioPath, []byte("local-audio"), 0o644); err != nil {
		t.Fatalf("seed audio: %v", err)
	}
	artworksDir := filepath.Join(config.GetUserDataPath(), "Artworks")
	if err := os.MkdirAll(artworksDir, 0o755); err != nil {
		t.Fatalf("create artworks dir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(artworksDir, "local-cover.webp"), []byte("cover-bytes"), 0o644); err != nil {
		t.Fatalf("seed artwork: %v", err)
	}
	if err := store.Instance.Save("library", []map[string]interface{}{
		{
			"id":          "local-track-1",
			"path":        audioPath,
			"title":       "Local Song",
			"artist":      "Artist",
			"album":       "Album",
			"albumartist": "Album Artist",
			"trackNumber": 7,
			"discNumber":  1,
			"genre":       "Rock",
			"year":        2026,
			"fileType":    ".flac",
			"artwork":     map[string]interface{}{"full": "local-cover.webp"},
		},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}
	if err := store.Instance.Save("playcounts", map[string]interface{}{
		audioPath: map[string]interface{}{
			"count":   4,
			"history": []interface{}{"2026-06-09T10:00:00Z"},
		},
	}); err != nil {
		t.Fatalf("seed playcounts: %v", err)
	}

	observer := &handlerObserver{}
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{DeviceID: "dev_remote_pc", DisplayName: "mainPC"})
		case "/sync/library/import":
			if err := r.ParseMultipartForm(32 << 20); err != nil {
				observer.errorf("parse multipart: %v", err)
				http.Error(w, "bad multipart", http.StatusBadRequest)
				return
			}
			var req syncLibraryImportRequest
			if err := json.Unmarshal([]byte(r.FormValue("metadata")), &req); err != nil {
				observer.errorf("decode metadata: %v", err)
				http.Error(w, "bad metadata", http.StatusBadRequest)
				return
			}
			if req.Track["title"] != "Local Song" || req.Track["artist"] != "Artist" || req.Track["album"] != "Album" || req.Track["albumartist"] != "Album Artist" {
				observer.errorf("metadata was not preserved: %#v", req.Track)
			}
			if req.Track["trackNumber"] != float64(7) || req.Track["discNumber"] != float64(1) || req.Track["genre"] != "Rock" || req.Track["year"] != float64(2026) {
				observer.errorf("numeric metadata was not preserved: %#v", req.Track)
			}
			playCount, _ := req.Track["syncPlayCount"].(map[string]interface{})
			if playCount["count"] != float64(4) {
				observer.errorf("expected playcount metadata, got %#v", req.Track)
			}
			artwork, _, err := r.FormFile("artwork")
			if err != nil {
				observer.errorf("expected artwork part: %v", err)
				http.Error(w, "missing artwork part", http.StatusBadRequest)
				return
			}
			defer artwork.Close()
			artworkBytes, err := io.ReadAll(artwork)
			if err != nil {
				observer.errorf("read artwork: %v", err)
				http.Error(w, "unreadable artwork", http.StatusBadRequest)
				return
			}
			if string(artworkBytes) != "cover-bytes" {
				observer.errorf("unexpected artwork bytes %q", string(artworkBytes))
			}
			writeJSON(w, syncLibraryImportResponse{Imported: true, Path: `C:\SyncLibrary\local.flac`})
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()

	result, err := NewApp().PushSyncLibraryAssets(remote.URL, 0)
	observer.assertNoErrors(t)
	if err != nil {
		t.Fatalf("PushSyncLibraryAssets: %v", err)
	}
	if result.Transferred != 1 || result.Failed != 0 {
		t.Fatalf("unexpected push result: %#v", result)
	}
}

func TestSyncLibraryImportAppliesUploadedArtworkAndPlayCount(t *testing.T) {
	newTempSyncStore(t)
	token := ensureSyncAuthTokenForDevice("dev_mac_mini")

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	metadata, err := writer.CreateFormField("metadata")
	if err != nil {
		t.Fatalf("create metadata field: %v", err)
	}
	if err := json.NewEncoder(metadata).Encode(syncLibraryImportRequest{
		SourceDeviceID:    "dev_mac_mini",
		SourceDisplayName: "YukinoMac-mini",
		Track: map[string]interface{}{
			"id":          "track-1",
			"title":       "Song",
			"artist":      "Artist",
			"album":       "Album",
			"albumartist": "Artist",
			"fileType":    ".flac",
			"syncPlayCount": map[string]interface{}{
				"count":   3,
				"history": []interface{}{"2026-06-09T10:00:00Z"},
			},
		},
	}); err != nil {
		t.Fatalf("write metadata: %v", err)
	}
	artwork, err := writer.CreateFormFile("artwork", "cover.webp")
	if err != nil {
		t.Fatalf("create artwork part: %v", err)
	}
	if _, err := artwork.Write([]byte("cover-bytes")); err != nil {
		t.Fatalf("write artwork: %v", err)
	}
	file, err := writer.CreateFormFile("file", "song.flac")
	if err != nil {
		t.Fatalf("create file part: %v", err)
	}
	if _, err := file.Write([]byte("uploaded-audio")); err != nil {
		t.Fatalf("write file: %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close writer: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/sync/library/import", &body)
	req.Header.Set("Content-Type", writer.FormDataContentType())
	req.Header.Set("X-UX-Music-Sync-Token", token)
	rec := httptest.NewRecorder()
	NewLANHTTPHandler(NewApp()).ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status %d: %s", rec.Code, rec.Body.String())
	}

	library, err := store.Instance.LoadSlice("library")
	if err != nil {
		t.Fatalf("load library: %v", err)
	}
	imported := library[0].(map[string]interface{})
	requireSyncArtworkFiles(t, imported, "uploaded import")
	importedPath, _ := imported["path"].(string)
	counts, err := store.Instance.LoadMap("playcounts")
	if err != nil {
		t.Fatalf("load playcounts: %v", err)
	}
	entry, _ := counts[importedPath].(map[string]interface{})
	if entry["count"] != float64(3) {
		t.Fatalf("expected imported playcount under imported path, got %#v", counts)
	}
}

func TestPushSyncLibraryAssetsWithOptionsTranscodesLosslessToMP3320(t *testing.T) {
	newTempSyncStore(t)
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey:   "dev_local_mac",
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_remote_pc": "tok_remote"},
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	dir := t.TempDir()
	audioPath := filepath.Join(dir, "local.flac")
	if err := os.WriteFile(audioPath, []byte("flac-audio"), 0o644); err != nil {
		t.Fatalf("seed audio: %v", err)
	}
	if err := store.Instance.Save("library", []map[string]interface{}{
		{
			"id":       "local-track-1",
			"path":     audioPath,
			"title":    "Local Song",
			"artist":   "Artist",
			"album":    "Album",
			"fileType": ".flac",
		},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}

	originalOpen := syncOpenMP3Stream
	syncOpenMP3Stream = func(_ context.Context, inputPath string) (io.ReadCloser, func() error, error) {
		if inputPath != audioPath {
			t.Fatalf("unexpected transcode input %q", inputPath)
		}
		return io.NopCloser(strings.NewReader("mp3-320-audio")), func() error { return nil }, nil
	}
	t.Cleanup(func() { syncOpenMP3Stream = originalOpen })

	observer := &handlerObserver{}
	var observedFileName string
	var observedFileType string
	var observedEncoding string
	var observedBitrate float64
	var observedBytes string
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{DeviceID: "dev_remote_pc", DisplayName: "mainPC"})
		case "/sync/library/import":
			if err := r.ParseMultipartForm(32 << 20); err != nil {
				observer.errorf("parse multipart: %v", err)
				http.Error(w, "bad multipart", http.StatusBadRequest)
				return
			}
			var req syncLibraryImportRequest
			if err := json.Unmarshal([]byte(r.FormValue("metadata")), &req); err != nil {
				observer.errorf("decode metadata: %v", err)
				http.Error(w, "bad metadata", http.StatusBadRequest)
				return
			}
			observedFileType, _ = req.Track["fileType"].(string)
			observedEncoding, _ = req.Track["syncTransferEncoding"].(string)
			observedBitrate, _ = req.Track["audioBitrateKbps"].(float64)
			file, header, err := r.FormFile("file")
			if err != nil {
				observer.errorf("read file part: %v", err)
				http.Error(w, "missing file part", http.StatusBadRequest)
				return
			}
			defer file.Close()
			observedFileName = header.Filename
			payload, err := io.ReadAll(file)
			if err != nil {
				observer.errorf("read payload: %v", err)
				http.Error(w, "unreadable payload", http.StatusBadRequest)
				return
			}
			observedBytes = string(payload)
			writeJSON(w, syncLibraryImportResponse{Imported: true, Path: `C:\SyncLibrary\local.mp3`})
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()

	result, err := NewApp().PushSyncLibraryAssetsWithOptions(remote.URL, 0, SyncTransferOptions{
		EncodingMode: syncTransferEncodingMP3320,
	})
	observer.assertNoErrors(t)
	if err != nil {
		t.Fatalf("PushSyncLibraryAssetsWithOptions: %v", err)
	}
	if result.Transferred != 1 || observedFileName != "local.mp3" || observedBytes != "mp3-320-audio" {
		t.Fatalf("unexpected push result=%#v filename=%q bytes=%q", result, observedFileName, observedBytes)
	}
	if observedFileType != ".mp3" || observedEncoding != syncTransferEncodingMP3320 || observedBitrate != 320 {
		t.Fatalf("unexpected metadata fileType=%q encoding=%q bitrate=%v", observedFileType, observedEncoding, observedBitrate)
	}
}

func TestPushSyncLibraryAssetsWithOptionsStreamsMP3EncodingIntoUpload(t *testing.T) {
	newTempSyncStore(t)
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey:   "dev_local_mac",
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_remote_pc": "tok_remote"},
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	dir := t.TempDir()
	audioPath := filepath.Join(dir, "local.flac")
	if err := os.WriteFile(audioPath, []byte("flac-audio"), 0o644); err != nil {
		t.Fatalf("seed audio: %v", err)
	}
	if err := store.Instance.Save("library", []map[string]interface{}{
		{
			"id":       "local-track-1",
			"path":     audioPath,
			"title":    "Local Song",
			"fileType": ".flac",
		},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}

	encoderCanFinish := make(chan struct{})
	uploadSawFirstBytes := make(chan struct{})
	var finishEncoderOnce sync.Once
	finishEncoder := func() { finishEncoderOnce.Do(func() { close(encoderCanFinish) }) }
	var uploadSawFirstBytesOnce sync.Once
	signalUploadSawFirstBytes := func() { uploadSawFirstBytesOnce.Do(func() { close(uploadSawFirstBytes) }) }
	observer := &handlerObserver{}
	// failUpload はハンドラー／エンコーダー側の異常を記録したうえで、待ち受け側と
	// エンコーダーの両方を解放する。
	//   - 待ち受け側を解放しないとテストは 2 秒待ってから「mp3 が届かない」という
	//     無関係な理由で落ち、本当の失敗理由が見えなくなる。
	//   - エンコーダーを解放しないと push 側がリクエストボディを送り切れず、
	//     ハンドラー復帰後にサーバーが残りのボディを読み切ろうとする段階で
	//     remote.Close() ごと止まる（finishEncoder は t.Cleanup 実行時、つまり
	//     defer remote.Close() より後にしか走らない）。
	failUpload := func(format string, args ...interface{}) {
		observer.errorf(format, args...)
		signalUploadSawFirstBytes()
		finishEncoder()
	}
	var encoderFinishedMu sync.Mutex
	encoderFinished := false
	originalOpen := syncOpenMP3Stream
	syncOpenMP3Stream = func(_ context.Context, inputPath string) (io.ReadCloser, func() error, error) {
		// このフックは push を走らせている別ゴルーチンから呼ばれるため、
		// t.Fatalf ではなく記録＋エラー返却で終わらせる。
		if inputPath != audioPath {
			failUpload("unexpected transcode input %q", inputPath)
			return nil, nil, errTestSyncTranscodeFailed
		}
		reader, writer := io.Pipe()
		go func() {
			_, _ = writer.Write([]byte("mp3-"))
			<-encoderCanFinish
			_, _ = writer.Write([]byte("stream"))
			encoderFinishedMu.Lock()
			encoderFinished = true
			encoderFinishedMu.Unlock()
			_ = writer.Close()
		}()
		return reader, func() error { return nil }, nil
	}
	t.Cleanup(func() {
		finishEncoder()
		syncOpenMP3Stream = originalOpen
	})

	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{DeviceID: "dev_remote_pc", DisplayName: "mainPC"})
		case "/sync/library/import":
			_, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
			if err != nil {
				failUpload("parse content type: %v", err)
				http.Error(w, "bad content type", http.StatusBadRequest)
				return
			}
			multipartReader := multipart.NewReader(r.Body, params["boundary"])
			for {
				part, err := multipartReader.NextPart()
				if err == io.EOF {
					break
				}
				if err != nil {
					failUpload("next part: %v", err)
					http.Error(w, "bad multipart", http.StatusBadRequest)
					return
				}
				if part.FormName() != "file" {
					_, _ = io.Copy(io.Discard, part)
					continue
				}
				buf := make([]byte, 4)
				if _, err := io.ReadFull(part, buf); err != nil {
					failUpload("read first upload bytes: %v", err)
					http.Error(w, "unreadable payload", http.StatusBadRequest)
					return
				}
				if string(buf) != "mp3-" {
					failUpload("unexpected first upload bytes %q", string(buf))
					http.Error(w, "unexpected payload", http.StatusBadRequest)
					return
				}
				encoderFinishedMu.Lock()
				finishedBeforeFirstBytes := encoderFinished
				encoderFinishedMu.Unlock()
				if finishedBeforeFirstBytes {
					failUpload("expected upload to start before mp3 encoder finished")
					http.Error(w, "upload started after encoder finished", http.StatusInternalServerError)
					return
				}
				signalUploadSawFirstBytes()
				finishEncoder()
				rest, err := io.ReadAll(part)
				if err != nil {
					failUpload("read remaining upload: %v", err)
					http.Error(w, "unreadable payload", http.StatusBadRequest)
					return
				}
				if string(rest) != "stream" {
					failUpload("unexpected remaining upload bytes %q", string(rest))
					http.Error(w, "unexpected payload", http.StatusBadRequest)
					return
				}
			}
			writeJSON(w, syncLibraryImportResponse{Imported: true, Path: `C:\SyncLibrary\local.mp3`})
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()

	done := make(chan error, 1)
	go func() {
		_, err := NewApp().PushSyncLibraryAssetsWithOptions(remote.URL, 1, SyncTransferOptions{
			EncodingMode: syncTransferEncodingMP3320,
		})
		done <- err
	}()

	select {
	case <-uploadSawFirstBytes:
	case <-time.After(2 * time.Second):
		// タイムアウトより先にハンドラー側の記録を吐き出す。
		// そちらが本当の失敗理由であることが多い。
		observer.assertNoErrors(t)
		t.Fatalf("upload did not receive mp3 bytes while encoder stream was still open")
	}
	observer.assertNoErrors(t)
	select {
	case err := <-done:
		observer.assertNoErrors(t)
		if err != nil {
			t.Fatalf("PushSyncLibraryAssetsWithOptions: %v", err)
		}
	case <-time.After(2 * time.Second):
		observer.assertNoErrors(t)
		t.Fatalf("push did not finish after encoder stream completed")
	}
}

func TestPushSyncLibraryAssetsEmitsTransferProgressWithFileAndSpeed(t *testing.T) {
	newTempSyncStore(t)
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncDeviceIDSettingsKey:   "dev_local_mac",
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_remote_pc": "tok_remote"},
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	dir := t.TempDir()
	audioPath := filepath.Join(dir, "local.flac")
	if err := os.WriteFile(audioPath, bytes.Repeat([]byte("a"), 64*1024), 0o644); err != nil {
		t.Fatalf("seed audio: %v", err)
	}
	if err := store.Instance.Save("library", []map[string]interface{}{
		{"id": "local-track-1", "path": audioPath, "title": "Local Song", "fileType": ".flac"},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}

	var progressEvents []SyncTransferProgress
	originalSink := syncTransferProgressSink
	syncTransferProgressSink = func(_ context.Context, progress SyncTransferProgress) {
		progressEvents = append(progressEvents, progress)
	}
	t.Cleanup(func() { syncTransferProgressSink = originalSink })

	observer := &handlerObserver{}
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{DeviceID: "dev_remote_pc", DisplayName: "mainPC"})
		case "/sync/library/import":
			if _, err := io.Copy(io.Discard, r.Body); err != nil {
				observer.errorf("read request: %v", err)
				http.Error(w, "unreadable request", http.StatusBadRequest)
				return
			}
			writeJSON(w, syncLibraryImportResponse{Imported: true, Path: `C:\SyncLibrary\local.flac`})
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()

	_, pushErr := NewApp().PushSyncLibraryAssetsWithOptions(remote.URL, 1, SyncTransferOptions{})
	observer.assertNoErrors(t)
	if pushErr != nil {
		t.Fatalf("PushSyncLibraryAssetsWithOptions: %v", pushErr)
	}

	var uploading *SyncTransferProgress
	for i := range progressEvents {
		if progressEvents[i].Stage == syncTransferStageUploading {
			uploading = &progressEvents[i]
		}
	}
	if uploading == nil {
		t.Fatalf("expected uploading progress event, got %#v", progressEvents)
	}
	if uploading.Direction != syncTransferDirectionPush || uploading.FileName != "local.flac" || uploading.Current != 1 || uploading.Total != 1 {
		t.Fatalf("unexpected uploading progress: %#v", uploading)
	}
	if uploading.BytesDone <= 0 || uploading.BytesTotal <= 0 || uploading.BytesPerSecond <= 0 {
		t.Fatalf("expected byte counters and transfer speed: %#v", uploading)
	}
}

func TestPullSyncLibraryAssetsDownloadsRemoteTrackIntoManagedLibrary(t *testing.T) {
	newTempSyncStore(t)
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_host": "tok_host"},
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}

	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{DeviceID: "dev_host", DisplayName: "Mac mini"})
		case "/sync/library/snapshot":
			if r.Header.Get("X-UX-Music-Sync-Token") != "tok_host" {
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}
			writeJSON(w, syncLibrarySnapshotResponse{
				Count: 1,
				Tracks: []map[string]interface{}{
					{
						"id":          "remote-track-1",
						"path":        "/Volumes/Music/source.flac",
						"title":       "Song",
						"artist":      "Artist",
						"album":       "Album",
						"albumartist": "Artist",
						"fileType":    ".flac",
						"syncPlayCount": map[string]interface{}{
							"count":   7,
							"history": []interface{}{"2026-06-10T01:00:00Z"},
						},
					},
				},
			})
		case "/sync/assets/remote-track-1/file":
			if r.Header.Get("X-UX-Music-Sync-Token") != "tok_host" {
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}
			w.Header().Set("Content-Disposition", `attachment; filename="source.flac"`)
			_, _ = w.Write([]byte("remote-audio"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()

	result, err := NewApp().PullSyncLibraryAssets(remote.URL, 0)
	if err != nil {
		t.Fatalf("PullSyncLibraryAssets: %v", err)
	}
	if result.Downloaded != 1 || result.Skipped != 0 {
		t.Fatalf("unexpected pull result: %#v", result)
	}

	library, err := store.Instance.LoadSlice("library")
	if err != nil {
		t.Fatalf("load library: %v", err)
	}
	if len(library) != 1 {
		t.Fatalf("expected one imported track, got %#v", library)
	}
	imported := library[0].(map[string]interface{})
	importedPath, _ := imported["path"].(string)
	if imported["syncSourceDeviceId"] != "dev_host" || imported["syncSourceTrackId"] != "remote-track-1" {
		t.Fatalf("missing source markers: %#v", imported)
	}
	if !filepath.IsAbs(importedPath) || filepath.Dir(importedPath) == config.GetUserDataPath() {
		t.Fatalf("expected managed nested destination, got %q", importedPath)
	}
	bytes, err := os.ReadFile(importedPath)
	if err != nil {
		t.Fatalf("read imported file: %v", err)
	}
	if string(bytes) != "remote-audio" {
		t.Fatalf("unexpected imported bytes %q", string(bytes))
	}
	counts, err := store.Instance.LoadMap("playcounts")
	if err != nil {
		t.Fatalf("load playcounts: %v", err)
	}
	entry, _ := counts[importedPath].(map[string]interface{})
	if entry["count"] != float64(7) {
		t.Fatalf("expected imported playcount at %q, got %#v", importedPath, counts)
	}
}

func TestPullSyncLibraryAssetsUpdatesPlayCountWhenImportedTrackAlreadyExists(t *testing.T) {
	newTempSyncStore(t)
	importedPath := filepath.Join(t.TempDir(), "song.flac")
	if err := os.WriteFile(importedPath, []byte("existing-audio"), 0o644); err != nil {
		t.Fatalf("seed existing audio: %v", err)
	}
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_host": "tok_host"},
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	if err := store.Instance.Save("library", []map[string]interface{}{
		{
			"id":                 "imported-local",
			"path":               importedPath,
			"title":              "Song",
			"artist":             "Artist",
			"album":              "Album",
			"duration":           123.4,
			"syncSourceDeviceId": "dev_host",
			"syncSourceTrackId":  "remote-track-1",
		},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}

	assetRequests := 0
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{DeviceID: "dev_host", DisplayName: "Mac mini"})
		case "/sync/library/snapshot":
			if r.Header.Get("X-UX-Music-Sync-Token") != "tok_host" {
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}
			writeJSON(w, syncLibrarySnapshotResponse{
				Count: 1,
				Tracks: []map[string]interface{}{{
					"id":       "remote-track-1",
					"title":    "Song",
					"artist":   "Artist",
					"album":    "Album",
					"duration": 123.4,
					"syncPlayCount": map[string]interface{}{
						"count":   42,
						"history": []interface{}{"2026-06-10T02:00:00Z"},
					},
				}},
			})
		case "/sync/assets/remote-track-1/file":
			assetRequests++
			http.Error(w, "already imported track should be skipped", http.StatusInternalServerError)
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()

	result, err := NewApp().PullSyncLibraryAssets(remote.URL, 0)
	if err != nil {
		t.Fatalf("PullSyncLibraryAssets: %v", err)
	}
	if result.Downloaded != 0 || result.Skipped != 1 || result.Failed != 0 {
		t.Fatalf("expected imported track to be skipped, got %#v", result)
	}
	if assetRequests != 0 {
		t.Fatalf("expected no asset request, got %d", assetRequests)
	}
	counts, err := store.Instance.LoadMap("playcounts")
	if err != nil {
		t.Fatalf("load playcounts: %v", err)
	}
	entry, _ := counts[importedPath].(map[string]interface{})
	if entry["count"] != float64(42) {
		t.Fatalf("expected existing imported track playcount to update, got %#v", counts)
	}
}

func TestPullSyncLibraryAssetsSkipsRemoteTrackWhenLocalMatchExists(t *testing.T) {
	newTempSyncStore(t)
	localPath := filepath.Join(t.TempDir(), "local.flac")
	if err := os.WriteFile(localPath, []byte("local-audio"), 0o644); err != nil {
		t.Fatalf("seed local audio: %v", err)
	}
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_host": "tok_host"},
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	if err := store.Instance.Save("library", []map[string]interface{}{
		{
			"id":       "local-track-1",
			"path":     localPath,
			"title":    "Song",
			"artist":   "Artist",
			"album":    "Album",
			"duration": 123.4,
			"fileType": ".flac",
		},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}

	assetRequests := 0
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{DeviceID: "dev_host", DisplayName: "MacBook Air"})
		case "/sync/library/snapshot":
			if r.Header.Get("X-UX-Music-Sync-Token") != "tok_host" {
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}
			writeJSON(w, syncLibrarySnapshotResponse{
				Count: 1,
				Tracks: []map[string]interface{}{
					{
						"id":       "remote-track-1",
						"path":     "/Users/yuki/Music/remote.mp3",
						"title":    "Song",
						"artist":   "Artist",
						"album":    "Album",
						"duration": 123.4,
						"fileType": ".mp3",
					},
				},
			})
		case "/sync/assets/remote-track-1/file":
			assetRequests++
			http.Error(w, "should not download duplicate local match", http.StatusInternalServerError)
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()

	result, err := NewApp().PullSyncLibraryAssets(remote.URL, 0)
	if err != nil {
		t.Fatalf("PullSyncLibraryAssets: %v", err)
	}
	if result.Downloaded != 0 || result.Skipped != 1 || result.Failed != 0 {
		t.Fatalf("expected duplicate local match to be skipped, got %#v", result)
	}
	if assetRequests != 0 {
		t.Fatalf("expected no asset download for duplicate local match, got %d", assetRequests)
	}
	library, err := store.Instance.LoadSlice("library")
	if err != nil {
		t.Fatalf("load library: %v", err)
	}
	if len(library) != 1 {
		t.Fatalf("expected local library to remain one track, got %#v", library)
	}
	remaining := library[0].(map[string]interface{})
	if remaining["id"] != "local-track-1" || remaining["path"] != localPath {
		t.Fatalf("unexpected local track after duplicate skip: %#v", remaining)
	}
}

func TestSyncMissingArtworkFromPeerContinuesAfterTrackError(t *testing.T) {
	newTempSyncStore(t)
	if err := store.Instance.Save("library", []map[string]interface{}{
		{"id": "local-1", "path": filepath.Join(t.TempDir(), "one.flac"), "syncSourceDeviceId": "dev_host", "syncSourceTrackId": "track-1"},
		{"id": "local-2", "path": filepath.Join(t.TempDir(), "two.flac"), "syncSourceDeviceId": "dev_host", "syncSourceTrackId": "track-2"},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}

	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-UX-Music-Sync-Token") != "tok_host" {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		switch r.URL.Path {
		case "/sync/assets/track-1/artwork":
			http.Error(w, "temporary artwork failure", http.StatusInternalServerError)
		case "/sync/assets/track-2/artwork":
			w.Header().Set("Content-Disposition", `attachment; filename="cover.webp"`)
			_, _ = w.Write([]byte("cover-bytes"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()

	changed, err := syncMissingArtworkFromPeer(context.Background(), remote.URL, "tok_host", "dev_host")
	if err != nil {
		t.Fatalf("syncMissingArtworkFromPeer should continue after per-track error: %v", err)
	}
	if changed != 1 {
		t.Fatalf("expected one artwork update, got %d", changed)
	}
	library, err := store.Instance.LoadSlice("library")
	if err != nil {
		t.Fatalf("load library: %v", err)
	}
	first := library[0].(map[string]interface{})
	second := library[1].(map[string]interface{})
	if _, exists := first["artwork"]; exists {
		t.Fatalf("failed track should not receive artwork: %#v", first)
	}
	requireSyncArtworkFiles(t, second, "second track artwork backfill")
}

func TestPullSyncLibraryAssetsRequestsPreferredMP3320WhenPeerSupportsIt(t *testing.T) {
	newTempSyncStore(t)
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncAuthTokensSettingsKey:      map[string]interface{}{"dev_host": "tok_host"},
		syncPreferredFormatSettingsKey: syncTransferEncodingMP3320,
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}

	var observedAssetQuery string
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{
				DeviceID:     "dev_host",
				DisplayName:  "Mac mini",
				Capabilities: []string{"library.transcode.mp3-320.v1"},
			})
		case "/sync/library/snapshot":
			if r.Header.Get("X-UX-Music-Sync-Token") != "tok_host" {
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}
			writeJSON(w, syncLibrarySnapshotResponse{
				Count: 1,
				Tracks: []map[string]interface{}{
					{
						"id":          "remote-track-1",
						"path":        "/Volumes/Music/source.flac",
						"title":       "Song",
						"artist":      "Artist",
						"album":       "Album",
						"albumartist": "Artist",
						"fileType":    ".flac",
					},
				},
			})
		case "/sync/assets/remote-track-1/file":
			observedAssetQuery = r.URL.RawQuery
			if r.Header.Get("X-UX-Music-Sync-Token") != "tok_host" {
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}
			w.Header().Set("Content-Disposition", `attachment; filename="source.mp3"`)
			w.Header().Set("X-UX-Music-Sync-Transfer-Encoding", syncTransferEncodingMP3320)
			w.Header().Set("X-UX-Music-Sync-Audio-Bitrate", "320")
			_, _ = w.Write([]byte("remote-mp3"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()

	result, err := NewApp().PullSyncLibraryAssets(remote.URL, 0)
	if err != nil {
		t.Fatalf("PullSyncLibraryAssets: %v", err)
	}
	if result.Downloaded != 1 || observedAssetQuery != "encoding=mp3_320" {
		t.Fatalf("unexpected pull result=%#v query=%q", result, observedAssetQuery)
	}
	library, err := store.Instance.LoadSlice("library")
	if err != nil {
		t.Fatalf("load library: %v", err)
	}
	imported := library[0].(map[string]interface{})
	importedPath := imported["path"].(string)
	if filepath.Ext(importedPath) != ".mp3" {
		t.Fatalf("expected mp3 destination, got %q", importedPath)
	}
	if imported["syncTransferEncoding"] != syncTransferEncodingMP3320 || imported["audioBitrateKbps"] != float64(320) {
		t.Fatalf("missing mp3 transfer metadata: %#v", imported)
	}
}

func TestPullSyncLibraryAssetsFallsBackToOriginalWhenPeerLacksMP3320Capability(t *testing.T) {
	newTempSyncStore(t)
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncAuthTokensSettingsKey:      map[string]interface{}{"dev_host": "tok_host"},
		syncPreferredFormatSettingsKey: syncTransferEncodingMP3320,
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}

	var observedAssetQuery string
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{DeviceID: "dev_host", DisplayName: "Mac mini"})
		case "/sync/library/snapshot":
			writeJSON(w, syncLibrarySnapshotResponse{Count: 1, Tracks: []map[string]interface{}{{"id": "remote-track-1", "path": "/Volumes/Music/source.flac", "title": "Song"}}})
		case "/sync/assets/remote-track-1/file":
			observedAssetQuery = r.URL.RawQuery
			w.Header().Set("Content-Disposition", `attachment; filename="source.flac"`)
			_, _ = w.Write([]byte("remote-flac"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()

	result, err := NewApp().PullSyncLibraryAssets(remote.URL, 0)
	if err != nil {
		t.Fatalf("PullSyncLibraryAssets: %v", err)
	}
	if result.Downloaded != 1 || observedAssetQuery != "" {
		t.Fatalf("expected original fallback, result=%#v query=%q", result, observedAssetQuery)
	}
}

func TestPullSyncLibraryAssetsKeepsOriginalWhenPreferredFormatIsOriginal(t *testing.T) {
	newTempSyncStore(t)
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncAuthTokensSettingsKey:      map[string]interface{}{"dev_host": "tok_host"},
		syncPreferredFormatSettingsKey: syncTransferEncodingOriginal,
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}

	var observedAssetQuery string
	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{DeviceID: "dev_host", DisplayName: "Mac mini", Capabilities: []string{"library.transcode.mp3-320.v1"}})
		case "/sync/library/snapshot":
			writeJSON(w, syncLibrarySnapshotResponse{Count: 1, Tracks: []map[string]interface{}{{"id": "remote-track-1", "path": "/Volumes/Music/source.flac", "title": "Song"}}})
		case "/sync/assets/remote-track-1/file":
			observedAssetQuery = r.URL.RawQuery
			w.Header().Set("Content-Disposition", `attachment; filename="source.flac"`)
			_, _ = w.Write([]byte("remote-flac"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()

	result, err := NewApp().PullSyncLibraryAssets(remote.URL, 0)
	if err != nil {
		t.Fatalf("PullSyncLibraryAssets: %v", err)
	}
	if result.Downloaded != 1 || observedAssetQuery != "" {
		t.Fatalf("expected original request, result=%#v query=%q", result, observedAssetQuery)
	}
}

func TestResetSyncTestDataKeepsPairingSettingsAndClearsManagedMusicState(t *testing.T) {
	newTempSyncStore(t)
	userData := config.GetUserDataPath()
	if err := store.Instance.Save("settings", map[string]interface{}{
		syncAuthTokensSettingsKey: map[string]interface{}{"dev_host": "tok_host"},
		syncKnownPeersSettingsKey: []syncKnownPeerRecord{{DeviceID: "dev_host", BaseURL: "http://192.168.0.226:8765"}},
		"libraryPath":             filepath.Join(t.TempDir(), "old-library"),
	}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	for _, name := range []string{"library", "playcounts", "loudness", "analysed-queue", syncPlayEventsStoreName} {
		if err := store.Instance.Save(name, map[string]interface{}{"stale": true}); err != nil {
			t.Fatalf("seed %s: %v", name, err)
		}
	}
	for _, dir := range []string{"Artworks", "WearCache", "SyncLibrary", "Playlists"} {
		path := filepath.Join(userData, dir)
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatalf("seed dir %s: %v", dir, err)
		}
		if err := os.WriteFile(filepath.Join(path, "stale"), []byte("x"), 0o644); err != nil {
			t.Fatalf("seed dir file %s: %v", dir, err)
		}
	}

	result, err := ResetSyncTestData()
	if err != nil {
		t.Fatalf("ResetSyncTestData: %v", err)
	}
	if result.RemovedCount == 0 {
		t.Fatalf("expected reset to remove files or directories: %#v", result)
	}
	if _, err := os.Stat(store.Instance.GetPath("library")); !os.IsNotExist(err) {
		t.Fatalf("expected library store to be removed, stat err=%v", err)
	}
	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		t.Fatalf("load settings: %v", err)
	}
	if _, ok := settings[syncAuthTokensSettingsKey]; !ok {
		t.Fatalf("expected sync tokens to be preserved: %#v", settings)
	}
	if _, ok := settings[syncKnownPeersSettingsKey]; !ok {
		t.Fatalf("expected known peers to be preserved: %#v", settings)
	}
	wantLibraryPath := filepath.Join(userData, "SyncLibrary")
	if settings["libraryPath"] != wantLibraryPath {
		t.Fatalf("expected libraryPath to be reset to %q, got %#v", wantLibraryPath, settings["libraryPath"])
	}
}

// ペアリング済みピアが送ってくる multipart filename と albumartist は
// そのまま SyncLibrary 配下のパス組み立てに使われるため、traversal 文字列を
// 与えても書き込み先が管理ルート配下から外に出ないことを固定する。
// ※ ここで検証しているのは「現状の実際の挙動」。sanitiseFileName は "/" と "\"
// を "_" に置換し、末尾の "." / " " を落とすだけで ".." そのものは残す。
func TestSyncLibraryImportKeepsTraversalFilenamesUnderManagedRoot(t *testing.T) {
	newTempSyncStore(t)
	token := ensureSyncAuthTokenForDevice("dev_evil")

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	metadata, err := writer.CreateFormField("metadata")
	if err != nil {
		t.Fatalf("create metadata field: %v", err)
	}
	if err := json.NewEncoder(metadata).Encode(syncLibraryImportRequest{
		SourceDeviceID:    "dev_evil",
		SourceDisplayName: "../../../etc",
		Track: map[string]interface{}{
			"id":          "track-evil",
			"title":       "Evil",
			"artist":      "../../..",
			"albumartist": "../../..",
			"album":       "../..",
			"fileType":    ".flac",
		},
	}); err != nil {
		t.Fatalf("write metadata: %v", err)
	}
	file, err := writer.CreateFormFile("file", "../evil.flac")
	if err != nil {
		t.Fatalf("create file field: %v", err)
	}
	if _, err := file.Write([]byte("evil-audio")); err != nil {
		t.Fatalf("write file: %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close multipart: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/sync/library/import", bytes.NewReader(body.Bytes()))
	req.Header.Set("Content-Type", writer.FormDataContentType())
	req.Header.Set("X-UX-Music-Sync-Token", token)
	rec := httptest.NewRecorder()
	NewLANHTTPHandler(NewApp()).ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status %d: %s", rec.Code, rec.Body.String())
	}
	var response syncLibraryImportResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if !response.Imported || response.Path == "" {
		t.Fatalf("unexpected import response: %#v", response)
	}

	managedRoot := filepath.Join(config.GetUserDataPath(), syncManagedLibraryDirName)
	resolved, err := filepath.Abs(filepath.Clean(response.Path))
	if err != nil {
		t.Fatalf("resolve imported path: %v", err)
	}
	rootAbs, err := filepath.Abs(managedRoot)
	if err != nil {
		t.Fatalf("resolve managed root: %v", err)
	}
	rel, err := filepath.Rel(rootAbs, resolved)
	if err != nil {
		t.Fatalf("relativise imported path: %v", err)
	}
	if rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) || filepath.IsAbs(rel) {
		t.Fatalf("import escaped the managed SyncLibrary root: root=%q path=%q rel=%q", rootAbs, resolved, rel)
	}
	if _, err := os.Stat(resolved); err != nil {
		t.Fatalf("expected imported file to exist at %q: %v", resolved, err)
	}
	// 現状の挙動: 区切り文字は "_" になり、末尾のドットが落ちた形で 1 階層ずつに収まる。
	// Go の multipart は Filename に filepath.Base を掛けるため "../evil.flac" は "evil.flac" になる。
	wantRel := filepath.Join(".._.._.._etc", ".._.._", ".._", "evil.flac")
	if rel != wantRel {
		t.Fatalf("unexpected managed layout: got %q want %q", rel, wantRel)
	}
}
