package server

import (
	"bytes"
	"context"
	"encoding/json"
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

func TestSyncLibrarySnapshotRequiresTokenAndReturnsLibraryTracks(t *testing.T) {
	newTempSyncStore(t)
	token := ensureSyncAuthTokenForDevice("portable-client")
	if err := store.Instance.Save("library", []map[string]interface{}{
		{
			"id":     "track-1",
			"path":   filepath.Join(t.TempDir(), "song.flac"),
			"title":  "Song",
			"artist": "Artist",
			"artwork": map[string]interface{}{
				"full": "large artwork payload is omitted",
			},
		},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
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
				t.Fatalf("parse multipart: %v", err)
			}
			var req syncLibraryImportRequest
			if err := json.Unmarshal([]byte(r.FormValue("metadata")), &req); err != nil {
				t.Fatalf("decode metadata: %v", err)
			}
			observedSourceDeviceID = req.SourceDeviceID
			observedTrackID = syncTrackID(req.Track)
			file, _, err := r.FormFile("file")
			if err != nil {
				t.Fatalf("read file part: %v", err)
			}
			defer file.Close()
			payload, err := io.ReadAll(file)
			if err != nil {
				t.Fatalf("read payload: %v", err)
			}
			observedBytes = string(payload)
			writeJSON(w, syncLibraryImportResponse{Imported: true, Path: `C:\SyncLibrary\local.flac`})
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()

	result, err := NewApp().PushSyncLibraryAssets(remote.URL, 0)
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

	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{DeviceID: "dev_remote_pc", DisplayName: "mainPC"})
		case "/sync/library/import":
			if err := r.ParseMultipartForm(32 << 20); err != nil {
				t.Fatalf("parse multipart: %v", err)
			}
			var req syncLibraryImportRequest
			if err := json.Unmarshal([]byte(r.FormValue("metadata")), &req); err != nil {
				t.Fatalf("decode metadata: %v", err)
			}
			if req.Track["title"] != "Local Song" || req.Track["artist"] != "Artist" || req.Track["album"] != "Album" || req.Track["albumartist"] != "Album Artist" {
				t.Fatalf("metadata was not preserved: %#v", req.Track)
			}
			if req.Track["trackNumber"] != float64(7) || req.Track["discNumber"] != float64(1) || req.Track["genre"] != "Rock" || req.Track["year"] != float64(2026) {
				t.Fatalf("numeric metadata was not preserved: %#v", req.Track)
			}
			playCount, _ := req.Track["syncPlayCount"].(map[string]interface{})
			if playCount["count"] != float64(4) {
				t.Fatalf("expected playcount metadata, got %#v", req.Track)
			}
			artwork, _, err := r.FormFile("artwork")
			if err != nil {
				t.Fatalf("expected artwork part: %v", err)
			}
			defer artwork.Close()
			artworkBytes, err := io.ReadAll(artwork)
			if err != nil {
				t.Fatalf("read artwork: %v", err)
			}
			if string(artworkBytes) != "cover-bytes" {
				t.Fatalf("unexpected artwork bytes %q", string(artworkBytes))
			}
			writeJSON(w, syncLibraryImportResponse{Imported: true, Path: `C:\SyncLibrary\local.flac`})
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()

	result, err := NewApp().PushSyncLibraryAssets(remote.URL, 0)
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
	artworkMap, _ := imported["artwork"].(map[string]interface{})
	if artworkMap["full"] == "" || artworkMap["thumbnail"] == "" {
		t.Fatalf("expected imported artwork reference, got %#v", imported)
	}
	for _, key := range []string{"full", "thumbnail"} {
		name, _ := artworkMap[key].(string)
		path := filepath.Join(config.GetUserDataPath(), "Artworks", name)
		if key == "thumbnail" {
			path = filepath.Join(config.GetUserDataPath(), "Artworks", "thumbnails", name)
		}
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("expected %s artwork file %q: %v", key, path, err)
		}
	}
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
				t.Fatalf("parse multipart: %v", err)
			}
			var req syncLibraryImportRequest
			if err := json.Unmarshal([]byte(r.FormValue("metadata")), &req); err != nil {
				t.Fatalf("decode metadata: %v", err)
			}
			observedFileType, _ = req.Track["fileType"].(string)
			observedEncoding, _ = req.Track["syncTransferEncoding"].(string)
			observedBitrate, _ = req.Track["audioBitrateKbps"].(float64)
			file, header, err := r.FormFile("file")
			if err != nil {
				t.Fatalf("read file part: %v", err)
			}
			defer file.Close()
			observedFileName = header.Filename
			payload, err := io.ReadAll(file)
			if err != nil {
				t.Fatalf("read payload: %v", err)
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
	var encoderFinishedMu sync.Mutex
	encoderFinished := false
	originalOpen := syncOpenMP3Stream
	syncOpenMP3Stream = func(_ context.Context, inputPath string) (io.ReadCloser, func() error, error) {
		if inputPath != audioPath {
			t.Fatalf("unexpected transcode input %q", inputPath)
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
				t.Fatalf("parse content type: %v", err)
			}
			multipartReader := multipart.NewReader(r.Body, params["boundary"])
			for {
				part, err := multipartReader.NextPart()
				if err == io.EOF {
					break
				}
				if err != nil {
					t.Fatalf("next part: %v", err)
				}
				if part.FormName() != "file" {
					_, _ = io.Copy(io.Discard, part)
					continue
				}
				buf := make([]byte, 4)
				if _, err := io.ReadFull(part, buf); err != nil {
					t.Fatalf("read first upload bytes: %v", err)
				}
				if string(buf) != "mp3-" {
					t.Fatalf("unexpected first upload bytes %q", string(buf))
				}
				encoderFinishedMu.Lock()
				finishedBeforeFirstBytes := encoderFinished
				encoderFinishedMu.Unlock()
				if finishedBeforeFirstBytes {
					t.Fatalf("expected upload to start before mp3 encoder finished")
				}
				close(uploadSawFirstBytes)
				finishEncoder()
				rest, err := io.ReadAll(part)
				if err != nil {
					t.Fatalf("read remaining upload: %v", err)
				}
				if string(rest) != "stream" {
					t.Fatalf("unexpected remaining upload bytes %q", string(rest))
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
		t.Fatalf("upload did not receive mp3 bytes while encoder stream was still open")
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("PushSyncLibraryAssetsWithOptions: %v", err)
		}
	case <-time.After(2 * time.Second):
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

	remote := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/sync/identity":
			writeJSON(w, syncIdentityResponse{DeviceID: "dev_remote_pc", DisplayName: "mainPC"})
		case "/sync/library/import":
			if _, err := io.Copy(io.Discard, r.Body); err != nil {
				t.Fatalf("read request: %v", err)
			}
			writeJSON(w, syncLibraryImportResponse{Imported: true, Path: `C:\SyncLibrary\local.flac`})
		default:
			http.NotFound(w, r)
		}
	}))
	defer remote.Close()

	if _, err := NewApp().PushSyncLibraryAssetsWithOptions(remote.URL, 1, SyncTransferOptions{}); err != nil {
		t.Fatalf("PushSyncLibraryAssetsWithOptions: %v", err)
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
