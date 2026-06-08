package server

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/store"

	"github.com/google/uuid"
	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

const syncManagedLibraryDirName = "SyncLibrary"
const syncTransferProgressEventName = "ux-sync-transfer-progress"
const syncTransferEncodingOriginal = "original"
const syncTransferEncodingMP3320 = "mp3_320"
const syncTransferDirectionPull = "pull"
const syncTransferDirectionPush = "push"
const syncTransferStagePreparing = "preparing"
const syncTransferStageTranscoding = "transcoding"
const syncTransferStageDownloading = "downloading"
const syncTransferStageUploading = "uploading"
const syncTransferStageDone = "done"
const syncTransferStageSkipped = "skipped"
const syncTransferStageFailed = "failed"

var syncTransferProgressSink = emitSyncTransferProgress
var syncOpenMP3Stream = openSyncMP3Stream

type syncLibrarySnapshotResponse struct {
	DeviceID    string                   `json:"deviceId"`
	DisplayName string                   `json:"displayName"`
	Count       int                      `json:"count"`
	Tracks      []map[string]interface{} `json:"tracks"`
	GeneratedAt string                   `json:"generatedAt"`
}

type SyncPullResult struct {
	RemoteDeviceID    string   `json:"remoteDeviceId"`
	RemoteDisplayName string   `json:"remoteDisplayName"`
	Downloaded        int      `json:"downloaded"`
	Skipped           int      `json:"skipped"`
	Failed            int      `json:"failed"`
	ImportedPaths     []string `json:"importedPaths"`
	Errors            []string `json:"errors,omitempty"`
}

type SyncPushResult struct {
	RemoteDeviceID    string   `json:"remoteDeviceId"`
	RemoteDisplayName string   `json:"remoteDisplayName"`
	Transferred       int      `json:"transferred"`
	Skipped           int      `json:"skipped"`
	Failed            int      `json:"failed"`
	EncodingMode      string   `json:"encodingMode"`
	ImportedPaths     []string `json:"importedPaths"`
	Errors            []string `json:"errors,omitempty"`
}

type SyncTransferOptions struct {
	EncodingMode string `json:"encodingMode"`
}

type SyncTransferProgress struct {
	Direction      string  `json:"direction"`
	Stage          string  `json:"stage"`
	TrackID        string  `json:"trackId,omitempty"`
	Title          string  `json:"title,omitempty"`
	FileName       string  `json:"fileName,omitempty"`
	Current        int     `json:"current"`
	Total          int     `json:"total"`
	BytesDone      int64   `json:"bytesDone"`
	BytesTotal     int64   `json:"bytesTotal"`
	BytesPerSecond float64 `json:"bytesPerSecond"`
	EncodingMode   string  `json:"encodingMode"`
	UpdatedAt      string  `json:"updatedAt"`
}

type SyncResetResult struct {
	UserDataPath string   `json:"userDataPath"`
	Removed      []string `json:"removed"`
	RemovedCount int      `json:"removedCount"`
	LibraryPath  string   `json:"libraryPath"`
}

type syncLibraryImportRequest struct {
	SourceDeviceID    string                 `json:"sourceDeviceId"`
	SourceDisplayName string                 `json:"sourceDisplayName"`
	Track             map[string]interface{} `json:"track"`
}

type syncLibraryImportResponse struct {
	Imported bool   `json:"imported"`
	Skipped  bool   `json:"skipped"`
	Path     string `json:"path,omitempty"`
}

func syncLibrarySnapshotHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}
	library, err := store.Instance.LoadSlice("library")
	if err != nil {
		http.Error(w, "library store format is invalid", http.StatusInternalServerError)
		return
	}
	tracks := make([]map[string]interface{}, 0, len(library))
	for _, item := range library {
		song, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		clean := make(map[string]interface{}, len(song))
		for key, value := range song {
			if key == "artwork" {
				continue
			}
			clean[key] = value
		}
		tracks = append(tracks, clean)
	}
	writeJSON(w, syncLibrarySnapshotResponse{
		DeviceID:    ensureSyncDeviceID(),
		DisplayName: syncDisplayName(),
		Count:       len(tracks),
		Tracks:      tracks,
		GeneratedAt: time.Now().UTC().Format(time.RFC3339),
	})
}

func syncAssetFileHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}
	trackID := strings.TrimPrefix(r.URL.Path, "/sync/assets/")
	trackID = strings.TrimSuffix(trackID, "/file")
	trackID = strings.Trim(trackID, "/")
	if decoded, err := url.PathUnescape(trackID); err == nil {
		trackID = decoded
	}
	if trackID == "" || strings.ContainsAny(trackID, `/\`) {
		http.Error(w, "Forbidden", http.StatusForbidden)
		return
	}
	filePath := findSongPathByID(trackID)
	if filePath == "" {
		http.NotFound(w, r)
		return
	}
	if !filepath.IsAbs(filePath) {
		http.Error(w, "Forbidden", http.StatusForbidden)
		return
	}
	if _, err := os.Stat(filePath); err != nil {
		http.NotFound(w, r)
		return
	}
	safeName := filepath.Base(filePath)
	if safeName == "" || safeName == "." {
		safeName = "track"
	}
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename=%q`, safeName))
	http.ServeFile(w, r, filePath)
}

func syncLibraryImportHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}
	if err := r.ParseMultipartForm(64 << 20); err != nil {
		http.Error(w, "invalid multipart payload", http.StatusBadRequest)
		return
	}
	var payload syncLibraryImportRequest
	if err := json.Unmarshal([]byte(r.FormValue("metadata")), &payload); err != nil {
		http.Error(w, "invalid metadata", http.StatusBadRequest)
		return
	}
	payload.SourceDeviceID = strings.TrimSpace(payload.SourceDeviceID)
	payload.SourceDisplayName = normaliseSyncDisplayName(payload.SourceDisplayName)
	trackID := syncTrackID(payload.Track)
	if payload.SourceDeviceID == "" || trackID == "" {
		http.Error(w, "missing source device or track id", http.StatusBadRequest)
		return
	}
	if syncImportedTrackExists(payload.SourceDeviceID, trackID) {
		writeJSON(w, syncLibraryImportResponse{Skipped: true})
		return
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		http.Error(w, "missing file", http.StatusBadRequest)
		return
	}
	defer file.Close()
	path, err := importSyncUploadedTrack(payload, header, file)
	if err != nil {
		http.Error(w, "failed to import uploaded track", http.StatusInternalServerError)
		return
	}
	writeJSON(w, syncLibraryImportResponse{Imported: true, Path: path})
}

func (a *App) PullSyncLibraryAssets(baseURL string, limit int) (SyncPullResult, error) {
	ctx := context.Background()
	if a != nil && a.ctx != nil {
		ctx = a.ctx
	}
	baseURL, err := normaliseSyncBaseURL(baseURL)
	if err != nil {
		return SyncPullResult{}, err
	}
	identity, err := fetchSyncIdentity(ctx, baseURL)
	if err != nil {
		return SyncPullResult{}, err
	}
	token, err := loadSyncAuthTokenForDevice(identity.DeviceID)
	if err != nil {
		return SyncPullResult{}, err
	}
	snapshot, err := fetchSyncLibrarySnapshot(ctx, baseURL, token)
	if err != nil {
		return SyncPullResult{}, err
	}
	result := SyncPullResult{
		RemoteDeviceID:    identity.DeviceID,
		RemoteDisplayName: syncIdentityDisplayName(identity),
	}
	for _, track := range snapshot.Tracks {
		if limit > 0 && result.Downloaded >= limit {
			break
		}
		trackID := syncTrackID(track)
		if trackID == "" {
			result.Failed++
			result.Errors = append(result.Errors, "track id is missing")
			continue
		}
		if syncImportedTrackExists(identity.DeviceID, trackID) {
			result.Skipped++
			continue
		}
		importedPath, err := downloadSyncTrackAsset(ctx, a, baseURL, token, identity, track, result.Downloaded+result.Failed+result.Skipped+1, len(snapshot.Tracks))
		if err != nil {
			result.Failed++
			result.Errors = append(result.Errors, fmt.Sprintf("%s: %v", trackID, err))
			continue
		}
		result.Downloaded++
		result.ImportedPaths = append(result.ImportedPaths, importedPath)
	}
	return result, nil
}

func (a *App) PushSyncLibraryAssets(baseURL string, limit int) (SyncPushResult, error) {
	return a.PushSyncLibraryAssetsWithOptions(baseURL, limit, SyncTransferOptions{})
}

func (a *App) PushSyncLibraryAssetsWithOptions(baseURL string, limit int, options SyncTransferOptions) (SyncPushResult, error) {
	ctx := context.Background()
	if a != nil && a.ctx != nil {
		ctx = a.ctx
	}
	baseURL, err := normaliseSyncBaseURL(baseURL)
	if err != nil {
		return SyncPushResult{}, err
	}
	identity, err := fetchSyncIdentity(ctx, baseURL)
	if err != nil {
		return SyncPushResult{}, err
	}
	token, err := loadSyncAuthTokenForDevice(identity.DeviceID)
	if err != nil {
		return SyncPushResult{}, err
	}
	library, err := store.Instance.LoadSlice("library")
	if err != nil {
		return SyncPushResult{}, err
	}
	source := syncIdentityResponse{DeviceID: ensureSyncDeviceID(), DisplayName: syncDisplayName()}
	result := SyncPushResult{
		RemoteDeviceID:    identity.DeviceID,
		RemoteDisplayName: syncIdentityDisplayName(identity),
		EncodingMode:      normaliseSyncTransferEncodingMode(options.EncodingMode),
	}
	total := syncTransferCandidateCount(library, limit)
	for _, item := range library {
		if limit > 0 && result.Transferred >= limit {
			break
		}
		track, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		trackID := syncTrackID(track)
		if trackID == "" {
			result.Failed++
			result.Errors = append(result.Errors, "track id is missing")
			continue
		}
		current := result.Transferred + result.Failed + result.Skipped + 1
		if syncTrackString(track, "syncSourceDeviceId") == identity.DeviceID {
			result.Skipped++
			a.emitSyncTransferProgress(SyncTransferProgress{
				Direction:    syncTransferDirectionPush,
				Stage:        syncTransferStageSkipped,
				TrackID:      trackID,
				Title:        syncTrackString(track, "title"),
				FileName:     filepath.Base(syncTrackString(track, "path")),
				Current:      current,
				Total:        total,
				EncodingMode: result.EncodingMode,
			})
			continue
		}
		response, err := a.uploadSyncTrackAsset(ctx, baseURL, token, source, track, options, current, total)
		if err != nil {
			result.Failed++
			result.Errors = append(result.Errors, fmt.Sprintf("%s: %v", trackID, err))
			a.emitSyncTransferProgress(SyncTransferProgress{
				Direction:    syncTransferDirectionPush,
				Stage:        syncTransferStageFailed,
				TrackID:      trackID,
				Title:        syncTrackString(track, "title"),
				FileName:     filepath.Base(syncTrackString(track, "path")),
				Current:      current,
				Total:        total,
				EncodingMode: result.EncodingMode,
			})
			continue
		}
		if response.Skipped {
			result.Skipped++
			a.emitSyncTransferProgress(SyncTransferProgress{
				Direction:    syncTransferDirectionPush,
				Stage:        syncTransferStageSkipped,
				TrackID:      trackID,
				Title:        syncTrackString(track, "title"),
				FileName:     filepath.Base(syncTrackString(track, "path")),
				Current:      current,
				Total:        total,
				EncodingMode: result.EncodingMode,
			})
			continue
		}
		if response.Imported {
			result.Transferred++
			if response.Path != "" {
				result.ImportedPaths = append(result.ImportedPaths, response.Path)
			}
			a.emitSyncTransferProgress(SyncTransferProgress{
				Direction:    syncTransferDirectionPush,
				Stage:        syncTransferStageDone,
				TrackID:      trackID,
				Title:        syncTrackString(track, "title"),
				FileName:     filepath.Base(syncTrackString(track, "path")),
				Current:      current,
				Total:        total,
				EncodingMode: result.EncodingMode,
			})
		}
	}
	return result, nil
}

func fetchSyncLibrarySnapshot(ctx context.Context, baseURL, token string) (syncLibrarySnapshotResponse, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/sync/library/snapshot", nil)
	if err != nil {
		return syncLibrarySnapshotResponse{}, err
	}
	req.Header.Set("X-UX-Music-Sync-Token", token)
	resp, err := syncHTTPClient().Do(req)
	if err != nil {
		return syncLibrarySnapshotResponse{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return syncLibrarySnapshotResponse{}, fmt.Errorf("sync library snapshot request failed: %s", resp.Status)
	}
	var snapshot syncLibrarySnapshotResponse
	if err := json.NewDecoder(resp.Body).Decode(&snapshot); err != nil {
		return syncLibrarySnapshotResponse{}, err
	}
	return snapshot, nil
}

func downloadSyncTrackAsset(ctx context.Context, app *App, baseURL, token string, identity syncIdentityResponse, track map[string]interface{}, current, total int) (string, error) {
	trackID := syncTrackID(track)
	endpoint := baseURL + "/sync/assets/" + url.PathEscape(trackID) + "/file"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("X-UX-Music-Sync-Token", token)
	resp, err := syncAssetHTTPClient().Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("sync asset request failed: %s", resp.Status)
	}
	destPath := syncManagedTrackDestination(identity, track, syncResponseFileName(resp, track))
	if err := os.MkdirAll(filepath.Dir(destPath), 0o755); err != nil {
		return "", err
	}
	tmpPath := destPath + ".tmp"
	out, err := os.Create(tmpPath)
	if err != nil {
		return "", err
	}
	progress := newSyncProgressReader(resp.Body, resp.ContentLength, func(done, totalBytes int64, bytesPerSecond float64) {
		app.emitSyncTransferProgress(SyncTransferProgress{
			Direction:      syncTransferDirectionPull,
			Stage:          syncTransferStageDownloading,
			TrackID:        trackID,
			Title:          syncTrackString(track, "title"),
			FileName:       filepath.Base(destPath),
			Current:        current,
			Total:          total,
			BytesDone:      done,
			BytesTotal:     totalBytes,
			BytesPerSecond: bytesPerSecond,
			EncodingMode:   syncTransferEncodingOriginal,
		})
	})
	_, copyErr := io.Copy(out, progress)
	closeErr := out.Close()
	if copyErr != nil {
		_ = os.Remove(tmpPath)
		return "", copyErr
	}
	if closeErr != nil {
		_ = os.Remove(tmpPath)
		return "", closeErr
	}
	if err := os.Rename(tmpPath, destPath); err != nil {
		_ = os.Remove(tmpPath)
		return "", err
	}
	if err := upsertSyncImportedTrack(identity, track, destPath); err != nil {
		return "", err
	}
	app.emitSyncTransferProgress(SyncTransferProgress{
		Direction:    syncTransferDirectionPull,
		Stage:        syncTransferStageDone,
		TrackID:      trackID,
		Title:        syncTrackString(track, "title"),
		FileName:     filepath.Base(destPath),
		Current:      current,
		Total:        total,
		EncodingMode: syncTransferEncodingOriginal,
	})
	return destPath, nil
}

func importSyncUploadedTrack(payload syncLibraryImportRequest, header *multipart.FileHeader, file io.Reader) (string, error) {
	fileName := "track"
	if header != nil {
		fileName = filepath.Base(header.Filename)
	}
	identity := syncIdentityResponse{
		DeviceID:    payload.SourceDeviceID,
		DisplayName: payload.SourceDisplayName,
	}
	destPath := syncManagedTrackDestination(identity, payload.Track, fileName)
	if err := os.MkdirAll(filepath.Dir(destPath), 0o755); err != nil {
		return "", err
	}
	tmpPath := destPath + ".tmp"
	out, err := os.Create(tmpPath)
	if err != nil {
		return "", err
	}
	_, copyErr := io.Copy(out, file)
	closeErr := out.Close()
	if copyErr != nil {
		_ = os.Remove(tmpPath)
		return "", copyErr
	}
	if closeErr != nil {
		_ = os.Remove(tmpPath)
		return "", closeErr
	}
	if err := os.Rename(tmpPath, destPath); err != nil {
		_ = os.Remove(tmpPath)
		return "", err
	}
	if err := upsertSyncImportedTrack(identity, payload.Track, destPath); err != nil {
		return "", err
	}
	return destPath, nil
}

func (a *App) uploadSyncTrackAsset(ctx context.Context, baseURL, token string, source syncIdentityResponse, track map[string]interface{}, options SyncTransferOptions, current, total int) (syncLibraryImportResponse, error) {
	filePath := syncTrackString(track, "path")
	if filePath == "" {
		return syncLibraryImportResponse{}, fmt.Errorf("track file path is missing")
	}
	if !filepath.IsAbs(filePath) {
		return syncLibraryImportResponse{}, fmt.Errorf("track file path is not absolute")
	}
	fileInfo, err := os.Stat(filePath)
	if err != nil {
		return syncLibraryImportResponse{}, err
	}
	if fileInfo.IsDir() {
		return syncLibraryImportResponse{}, fmt.Errorf("track file path is a directory")
	}
	a.emitSyncTransferProgress(SyncTransferProgress{
		Direction:    syncTransferDirectionPush,
		Stage:        syncTransferStagePreparing,
		TrackID:      syncTrackID(track),
		Title:        syncTrackString(track, "title"),
		FileName:     filepath.Base(filePath),
		Current:      current,
		Total:        total,
		BytesTotal:   fileInfo.Size(),
		EncodingMode: normaliseSyncTransferEncodingMode(options.EncodingMode),
	})

	prepared, err := prepareSyncTrackForTransfer(ctx, track, options, func(stage string, preparedFileName string) {
		a.emitSyncTransferProgress(SyncTransferProgress{
			Direction:    syncTransferDirectionPush,
			Stage:        stage,
			TrackID:      syncTrackID(track),
			Title:        syncTrackString(track, "title"),
			FileName:     firstNonEmpty(preparedFileName, filepath.Base(filePath)),
			Current:      current,
			Total:        total,
			BytesTotal:   fileInfo.Size(),
			EncodingMode: normaliseSyncTransferEncodingMode(options.EncodingMode),
		})
	})
	if err != nil {
		return syncLibraryImportResponse{}, err
	}

	reader, writer := io.Pipe()
	multipartWriter := multipart.NewWriter(writer)
	go func() {
		var writeErr error
		defer func() {
			if cleanupErr := prepared.cleanup(); writeErr == nil {
				writeErr = cleanupErr
			}
			if closeErr := multipartWriter.Close(); writeErr == nil {
				writeErr = closeErr
			}
			if writeErr != nil {
				_ = writer.CloseWithError(writeErr)
			} else {
				_ = writer.Close()
			}
		}()
		metadata, err := multipartWriter.CreateFormField("metadata")
		if err != nil {
			writeErr = err
			return
		}
		if err := json.NewEncoder(metadata).Encode(syncLibraryImportRequest{
			SourceDeviceID:    source.DeviceID,
			SourceDisplayName: syncIdentityDisplayName(source),
			Track:             sanitiseSyncTrackForTransfer(prepared.track),
		}); err != nil {
			writeErr = err
			return
		}
		part, err := multipartWriter.CreateFormFile("file", prepared.fileName)
		if err != nil {
			writeErr = err
			return
		}
		progress := newSyncProgressReader(prepared.reader, prepared.size, func(done, totalBytes int64, bytesPerSecond float64) {
			a.emitSyncTransferProgress(SyncTransferProgress{
				Direction:      syncTransferDirectionPush,
				Stage:          syncTransferStageUploading,
				TrackID:        syncTrackID(track),
				Title:          syncTrackString(track, "title"),
				FileName:       prepared.fileName,
				Current:        current,
				Total:          total,
				BytesDone:      done,
				BytesTotal:     totalBytes,
				BytesPerSecond: bytesPerSecond,
				EncodingMode:   prepared.encodingMode,
			})
		})
		if _, err := io.Copy(part, progress); err != nil {
			writeErr = err
			return
		}
	}()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/sync/library/import", reader)
	if err != nil {
		return syncLibraryImportResponse{}, err
	}
	req.Header.Set("Content-Type", multipartWriter.FormDataContentType())
	req.Header.Set("X-UX-Music-Sync-Token", token)
	resp, err := syncAssetHTTPClient().Do(req)
	if err != nil {
		return syncLibraryImportResponse{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return syncLibraryImportResponse{}, fmt.Errorf("sync library import request failed: %s", resp.Status)
	}
	var result syncLibraryImportResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return syncLibraryImportResponse{}, err
	}
	return result, nil
}

type syncPreparedTransferTrack struct {
	reader       io.ReadCloser
	fileName     string
	size         int64
	track        map[string]interface{}
	encodingMode string
	cleanup      func() error
}

func prepareSyncTrackForTransfer(ctx context.Context, track map[string]interface{}, options SyncTransferOptions, notify func(stage string, fileName string)) (syncPreparedTransferTrack, error) {
	mode := normaliseSyncTransferEncodingMode(options.EncodingMode)
	sourcePath := syncTrackString(track, "path")
	if sourcePath == "" {
		return syncPreparedTransferTrack{}, fmt.Errorf("track file path is missing")
	}
	sourceInfo, err := os.Stat(sourcePath)
	if err != nil {
		return syncPreparedTransferTrack{}, err
	}
	preparedTrack := sanitiseSyncTrackForTransfer(track)
	if mode != syncTransferEncodingMP3320 || strings.EqualFold(filepath.Ext(sourcePath), ".mp3") {
		file, err := os.Open(sourcePath)
		if err != nil {
			return syncPreparedTransferTrack{}, err
		}
		var cleanupOnce sync.Once
		return syncPreparedTransferTrack{
			reader:       file,
			fileName:     filepath.Base(sourcePath),
			size:         sourceInfo.Size(),
			track:        preparedTrack,
			encodingMode: mode,
			cleanup: func() error {
				var cleanupErr error
				cleanupOnce.Do(func() {
					cleanupErr = file.Close()
				})
				return cleanupErr
			},
		}, nil
	}

	fileName := strings.TrimSuffix(filepath.Base(sourcePath), filepath.Ext(sourcePath)) + ".mp3"
	if notify != nil {
		notify(syncTransferStageTranscoding, filepath.Base(sourcePath))
	}
	reader, wait, err := syncOpenMP3Stream(ctx, sourcePath)
	if err != nil {
		return syncPreparedTransferTrack{}, err
	}
	preparedTrack["fileType"] = ".mp3"
	preparedTrack["syncTransferEncoding"] = syncTransferEncodingMP3320
	preparedTrack["audioBitrateKbps"] = 320
	var cleanupOnce sync.Once
	return syncPreparedTransferTrack{
		reader:       reader,
		fileName:     fileName,
		size:         -1,
		track:        preparedTrack,
		encodingMode: syncTransferEncodingMP3320,
		cleanup: func() error {
			var cleanupErr error
			cleanupOnce.Do(func() {
				closeErr := reader.Close()
				waitErr := wait()
				if waitErr != nil {
					cleanupErr = waitErr
					return
				}
				cleanupErr = closeErr
			})
			return cleanupErr
		},
	}, nil
}

func openSyncMP3Stream(ctx context.Context, inputPath string) (io.ReadCloser, func() error, error) {
	ffmpegPath, err := locateFfmpeg()
	if err != nil {
		return nil, nil, fmt.Errorf("ffmpeg not found: %w", err)
	}
	cmd := exec.CommandContext(ctx, ffmpegPath, "-i", inputPath, "-vn", "-codec:a", "libmp3lame", "-b:a", "320k", "-f", "mp3", "pipe:1")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, nil, err
	}
	wait := func() error {
		if err := cmd.Wait(); err != nil {
			return fmt.Errorf("ffmpeg mp3 stream failed: %w: %s", err, strings.TrimSpace(stderr.String()))
		}
		return nil
	}
	return stdout, wait, nil
}

type syncProgressReader struct {
	reader    io.Reader
	total     int64
	done      int64
	startedAt time.Time
	onRead    func(done, total int64, bytesPerSecond float64)
}

func newSyncProgressReader(reader io.Reader, total int64, onRead func(done, total int64, bytesPerSecond float64)) *syncProgressReader {
	return &syncProgressReader{
		reader:    reader,
		total:     total,
		startedAt: time.Now(),
		onRead:    onRead,
	}
}

func (r *syncProgressReader) Read(p []byte) (int, error) {
	n, err := r.reader.Read(p)
	if n > 0 {
		r.done += int64(n)
		elapsed := time.Since(r.startedAt).Seconds()
		bytesPerSecond := float64(r.done)
		if elapsed > 0 {
			bytesPerSecond = float64(r.done) / elapsed
		}
		if r.onRead != nil {
			r.onRead(r.done, r.total, bytesPerSecond)
		}
	}
	return n, err
}

func (a *App) emitSyncTransferProgress(progress SyncTransferProgress) {
	progress.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	syncTransferProgressSink(appContext(a), progress)
}

func emitSyncTransferProgress(ctx context.Context, progress SyncTransferProgress) {
	if ctx != nil {
		wailsRuntime.EventsEmit(ctx, syncTransferProgressEventName, progress)
	}
}

func appContext(a *App) context.Context {
	if a == nil {
		return nil
	}
	return a.ctx
}

func normaliseSyncTransferEncodingMode(raw string) string {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case syncTransferEncodingMP3320:
		return syncTransferEncodingMP3320
	default:
		return syncTransferEncodingOriginal
	}
}

func syncTransferCandidateCount(library []interface{}, limit int) int {
	if limit > 0 && limit < len(library) {
		return limit
	}
	return len(library)
}

func syncAssetHTTPClient() *http.Client {
	return &http.Client{Timeout: 10 * time.Minute}
}

func syncManagedTrackDestination(identity syncIdentityResponse, track map[string]interface{}, fileName string) string {
	if strings.TrimSpace(fileName) == "" || fileName == "." {
		fileName = syncTrackID(track)
	}
	if ext := strings.TrimSpace(syncTrackString(track, "fileType")); ext != "" && filepath.Ext(fileName) == "" {
		if !strings.HasPrefix(ext, ".") {
			ext = "." + ext
		}
		fileName += ext
	}
	deviceDir := sanitiseFileName(firstNonEmpty(identity.DisplayName, identity.DeviceID, "Remote Device"))
	artistDir := sanitiseFileName(firstNonEmpty(syncTrackString(track, "albumartist"), syncTrackString(track, "artist"), "Unknown Artist"))
	albumDir := sanitiseFileName(firstNonEmpty(syncTrackString(track, "album"), "Unknown Album"))
	return filepath.Join(config.GetUserDataPath(), syncManagedLibraryDirName, deviceDir, artistDir, albumDir, sanitiseFileName(fileName))
}

func syncResponseFileName(resp *http.Response, track map[string]interface{}) string {
	if resp != nil {
		if _, params, err := mime.ParseMediaType(resp.Header.Get("Content-Disposition")); err == nil {
			if filename := strings.TrimSpace(params["filename"]); filename != "" {
				return filepath.Base(filename)
			}
		}
	}
	if path := syncTrackString(track, "path"); path != "" {
		return filepath.Base(path)
	}
	return syncTrackID(track)
}

func upsertSyncImportedTrack(identity syncIdentityResponse, track map[string]interface{}, destPath string) error {
	library, err := store.Instance.LoadSlice("library")
	if err != nil {
		return err
	}
	trackID := syncTrackID(track)
	now := time.Now().UTC().Format(time.RFC3339)
	next := make(map[string]interface{}, len(track)+6)
	for key, value := range track {
		if key == "artwork" {
			continue
		}
		next[key] = value
	}
	next["id"] = uuid.NewString()
	next["path"] = destPath
	next["syncSourceDeviceId"] = identity.DeviceID
	next["syncSourceTrackId"] = trackID
	next["syncImportedAt"] = now
	if info, err := os.Stat(destPath); err == nil {
		next["fileSize"] = info.Size()
	}
	for i, item := range library {
		existing, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		if existing["syncSourceDeviceId"] == identity.DeviceID && existing["syncSourceTrackId"] == trackID {
			if id, _ := existing["id"].(string); strings.TrimSpace(id) != "" {
				next["id"] = id
			}
			library[i] = next
			return store.Instance.Save("library", library)
		}
	}
	library = append(library, next)
	return store.Instance.Save("library", library)
}

func syncImportedTrackExists(deviceID, trackID string) bool {
	library, err := store.Instance.LoadSlice("library")
	if err != nil {
		return false
	}
	for _, item := range library {
		existing, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		if existing["syncSourceDeviceId"] == deviceID && existing["syncSourceTrackId"] == trackID {
			if path, _ := existing["path"].(string); strings.TrimSpace(path) != "" {
				if _, err := os.Stat(path); err == nil {
					return true
				}
			}
		}
	}
	return false
}

func syncTrackID(track map[string]interface{}) string {
	return firstNonEmpty(syncTrackString(track, "id"), syncTrackString(track, "trackId"))
}

func syncTrackString(track map[string]interface{}, key string) string {
	if track == nil {
		return ""
	}
	switch value := track[key].(type) {
	case string:
		return strings.TrimSpace(value)
	case fmt.Stringer:
		return strings.TrimSpace(value.String())
	case float64:
		return strconv.FormatInt(int64(value), 10)
	case int:
		return strconv.Itoa(value)
	default:
		return ""
	}
}

func sanitiseSyncTrackForTransfer(track map[string]interface{}) map[string]interface{} {
	clean := make(map[string]interface{}, len(track))
	for key, value := range track {
		if key == "artwork" {
			continue
		}
		clean[key] = value
	}
	return clean
}

func loadSyncAuthTokenForDevice(deviceID string) (string, error) {
	deviceID = strings.TrimSpace(deviceID)
	if deviceID == "" {
		return "", fmt.Errorf("missing sync device id")
	}
	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		return "", err
	}
	rawTokens, _ := settings[syncAuthTokensSettingsKey].(map[string]interface{})
	token, _ := rawTokens[deviceID].(string)
	token = strings.TrimSpace(token)
	if token == "" {
		return "", fmt.Errorf("sync peer is not paired: %s", deviceID)
	}
	return token, nil
}

func ResetSyncTestData() (SyncResetResult, error) {
	userDataPath := config.GetUserDataPath()
	if strings.TrimSpace(userDataPath) == "" {
		return SyncResetResult{}, fmt.Errorf("user data path is not configured")
	}
	settings, err := store.Instance.LoadMap("settings")
	if err != nil {
		settings = map[string]interface{}{}
	}
	preserved := map[string]interface{}{}
	for _, key := range []string{syncDeviceIDSettingsKey, syncAuthTokensSettingsKey, syncKnownPeersSettingsKey} {
		if value, ok := settings[key]; ok {
			preserved[key] = value
		}
	}
	libraryPath := filepath.Join(userDataPath, syncManagedLibraryDirName)
	preserved["libraryPath"] = libraryPath

	result := SyncResetResult{UserDataPath: userDataPath, LibraryPath: libraryPath}
	for _, name := range []string{"library", "playcounts", "loudness", "analysed-queue", syncPlayEventsStoreName, "playlist-order"} {
		path := store.Instance.GetPath(name)
		if err := os.Remove(path); err == nil {
			result.Removed = append(result.Removed, path)
		} else if err != nil && !os.IsNotExist(err) {
			return result, err
		}
	}
	for _, dir := range []string{"Artworks", "WearCache", syncManagedLibraryDirName, "Playlists"} {
		path := filepath.Join(userDataPath, dir)
		if err := os.RemoveAll(path); err != nil {
			return result, err
		}
		result.Removed = append(result.Removed, path)
	}
	if err := os.MkdirAll(libraryPath, 0o755); err != nil {
		return result, err
	}
	store.Instance = &store.Store{}
	if err := store.Instance.Save("settings", preserved); err != nil {
		return result, err
	}
	result.RemovedCount = len(result.Removed)
	return result, nil
}
