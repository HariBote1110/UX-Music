package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/store"

	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

const wearServerPort = "8765"

// WearServer holds the HTTP server for the /wear/ endpoints.
type WearServer struct {
	server *http.Server
	app    *App
}

// StartWearServer starts the LAN HTTP server that serves the /wear/ API.
// It binds to 0.0.0.0:8765 so that iPhone, Apple Watch, and mobile
// companion apps on the same network can reach the UX Music library.
func StartWearServer(ctx context.Context, app *App) *WearServer {
	ws := &WearServer{app: app}

	mux := http.NewServeMux()
	mux.HandleFunc("/wear/ping", wearPingHandler)
	mux.HandleFunc("/wear/songs", wearSongsHandler)
	mux.HandleFunc("/wear/file/", wearFileHandler)
	mux.HandleFunc("/wear/artwork/", wearArtworkHandler)
	mux.HandleFunc("/wear/loudness", ws.wearLoudnessHandler)
	mux.HandleFunc("/wear/state", ws.wearStateHandler)
	mux.HandleFunc("/wear/command", ws.wearCommandHandler)

	srv := &http.Server{
		Addr:    "0.0.0.0:" + wearServerPort,
		Handler: corsMiddleware(mux),
	}

	go func() {
		fmt.Printf("[Wear] HTTP server listening on :%s\n", wearServerPort)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			fmt.Printf("[Wear] Server error: %v\n", err)
		}
	}()

	go func() {
		<-ctx.Done()
		_ = srv.Close()
	}()

	ws.server = srv
	return ws
}

// GetWearServerAddress returns the LAN address of this machine for display in the UI.
func GetWearServerAddress() string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return "localhost:" + wearServerPort
	}
	for _, addr := range addrs {
		if ipNet, ok := addr.(*net.IPNet); ok && !ipNet.IP.IsLoopback() {
			if ipNet.IP.To4() != nil {
				return ipNet.IP.String() + ":" + wearServerPort
			}
		}
	}
	return "localhost:" + wearServerPort
}

// ─── Handlers ───────────────────────────────────────────────────────────────

func wearPingHandler(w http.ResponseWriter, r *http.Request) {
	hostname, _ := os.Hostname()
	writeJSON(w, map[string]string{
		"version":  "0.1.0",
		"hostname": hostname,
	})
}

func wearSongsHandler(w http.ResponseWriter, r *http.Request) {
	raw, err := store.Instance.Load("library")
	if err != nil || raw == nil {
		writeJSON(w, []interface{}{})
		return
	}

	// Strip artwork blobs before sending to save bandwidth
	library, ok := raw.([]interface{})
	if !ok {
		writeJSON(w, []interface{}{})
		return
	}

	stripped := make([]map[string]interface{}, 0, len(library))
	for _, item := range library {
		song, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		clean := make(map[string]interface{}, len(song)+1)
		for k, v := range song {
			if k == "artwork" {
				continue
			}
			clean[k] = v
		}
		// Compute artwork ID (SHA256 hash of "albumArtist---album") so that
		// mobile clients can construct a valid /wear/artwork/{artworkId} URL.
		albumArtist, _ := song["albumartist"].(string)
		album, _ := song["album"].(string)
		clean["artworkId"] = computeArtworkID(albumArtist, album)
		stripped = append(stripped, clean)
	}

	writeJSON(w, stripped)
}

func wearFileHandler(w http.ResponseWriter, r *http.Request) {
	songID := strings.TrimPrefix(r.URL.Path, "/wear/file/")
	if songID == "" {
		http.Error(w, "missing song ID", http.StatusBadRequest)
		return
	}

	filePath := findSongPathByID(songID)
	if filePath == "" {
		http.NotFound(w, r)
		return
	}

	// Security: ensure the file path is absolute and exists
	if !filepath.IsAbs(filePath) {
		http.Error(w, "Forbidden", http.StatusForbidden)
		return
	}
	if _, err := os.Stat(filePath); err != nil {
		http.NotFound(w, r)
		return
	}

	// Try to serve a Watch-optimised transcoded version (AAC 128 kbps m4a).
	// Falls back to the original file if ffmpeg is unavailable or fails.
	cachedPath, err := getOrTranscode(songID, filePath)
	if err != nil {
		fmt.Printf("[Wear] Transcode failed for %s: %v — serving original\n", songID, err)
		http.ServeFile(w, r, filePath)
		return
	}

	// Tell the client this is an m4a so it uses the right file extension.
	w.Header().Set("Content-Disposition",
		fmt.Sprintf(`attachment; filename="%s.m4a"`, songID))
	http.ServeFile(w, r, cachedPath)
}

func wearArtworkHandler(w http.ResponseWriter, r *http.Request) {
	// Accept either /wear/artwork/{artworkId} (hash) or
	// a query param ?id={artworkId} for clients that cannot encode slashes.
	artworkID := r.URL.Query().Get("id")
	if artworkID == "" {
		artworkID = strings.TrimPrefix(r.URL.Path, "/wear/artwork/")
	}
	if artworkID == "" {
		http.Error(w, "missing artwork ID", http.StatusBadRequest)
		return
	}

	artworksDir := filepath.Join(config.GetUserDataPath(), "Artworks")

	// Security: artworkID must be a plain hex string (no path separators).
	if strings.ContainsAny(artworkID, "/\\") {
		http.Error(w, "Forbidden", http.StatusForbidden)
		return
	}

	artworkPath := findArtworkByID(artworkID, artworksDir)
	if artworkPath == "" {
		http.NotFound(w, r)
		return
	}

	// Security: must be inside artworksDir
	if !strings.HasPrefix(artworkPath, artworksDir) {
		http.Error(w, "Forbidden", http.StatusForbidden)
		return
	}

	http.ServeFile(w, r, artworkPath)
}

// ─── Mobile Companion Handlers ──────────────────────────────────────────────

// wearLoudnessHandler returns a map of songID → LUFS loudness value.
// Mobile clients use this to apply volume normalisation during local playback.
func (ws *WearServer) wearLoudnessHandler(w http.ResponseWriter, r *http.Request) {
	loudnessMap := loadLoudnessMap()
	if len(loudnessMap) == 0 {
		writeJSON(w, map[string]interface{}{})
		return
	}

	// Build a path→songID lookup from the library
	pathToID := buildPathToIDMap()

	// Re-key the loudness map from file paths to song IDs
	result := make(map[string]interface{}, len(loudnessMap))
	for path, lufs := range loudnessMap {
		if songID, ok := pathToID[path]; ok {
			result[songID] = lufs
		}
	}

	writeJSON(w, result)
}

// wearStateHandler returns the current desktop playback state.
func (ws *WearServer) wearStateHandler(w http.ResponseWriter, r *http.Request) {
	status := ws.app.AudioGetStatus()

	// Include current track metadata from OS media state
	ws.app.mediaStateMu.Lock()
	status["title"] = ws.app.mediaTitle
	status["artist"] = ws.app.mediaArtist
	status["album"] = ws.app.mediaAlbum
	ws.app.mediaStateMu.Unlock()

	writeJSON(w, status)
}

// wearCommandHandler accepts remote playback commands from mobile clients.
// Supported actions: toggle, play, pause, stop, next, prev, seek.
func (ws *WearServer) wearCommandHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, 1024))
	if err != nil {
		http.Error(w, "read body failed", http.StatusBadRequest)
		return
	}
	defer r.Body.Close()

	var cmd struct {
		Action string  `json:"action"`
		Value  float64 `json:"value,omitempty"`
	}
	if err := json.Unmarshal(body, &cmd); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}

	var cmdErr error
	switch cmd.Action {
	case "toggle":
		if ws.app.AudioIsPlaying() {
			cmdErr = ws.app.AudioPause()
		} else {
			cmdErr = ws.app.AudioResume()
		}
	case "play":
		cmdErr = ws.app.AudioResume()
	case "pause":
		cmdErr = ws.app.AudioPause()
	case "stop":
		cmdErr = ws.app.AudioStop()
	case "seek":
		cmdErr = ws.app.AudioSeek(cmd.Value)
	case "next", "prev":
		// Queue management lives in the Wails frontend; delegate via event
		if ws.app.ctx != nil {
			wailsRuntime.EventsEmit(ws.app.ctx, "remote-command", cmd.Action)
		}
	default:
		http.Error(w, "unknown action", http.StatusBadRequest)
		return
	}

	if cmdErr != nil {
		writeJSON(w, map[string]interface{}{"ok": false, "error": cmdErr.Error()})
		return
	}
	writeJSON(w, map[string]interface{}{"ok": true})
}

// buildPathToIDMap creates a reverse lookup from file path to song ID
// by scanning the library store.
func buildPathToIDMap() map[string]string {
	raw, err := store.Instance.Load("library")
	if err != nil || raw == nil {
		return nil
	}
	library, ok := raw.([]interface{})
	if !ok {
		return nil
	}
	m := make(map[string]string, len(library))
	for _, item := range library {
		song, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		id, _ := song["id"].(string)
		path, _ := song["path"].(string)
		if id != "" && path != "" {
			m[path] = id
		}
	}
	return m
}

// ─── Watch-optimised Transcoding ────────────────────────────────────────────

// transcodeOnce guards in-progress transcodings so that concurrent requests
// for the same song ID do not launch multiple ffmpeg processes.
var transcodeOnce sync.Map // key: songID, value: *sync.Mutex

// getOrTranscode returns the path to a Watch-optimised m4a for the given song.
// On first call it transcodes via ffmpeg and caches the result.
// On subsequent calls it returns the cached file immediately.
// Falls back to original if ffmpeg is not found or transcoding fails.
func getOrTranscode(songID, inputPath string) (string, error) {
	// Locate ffmpeg — common paths on macOS + PATH fallback
	ffmpegPath, err := locateFfmpeg()
	if err != nil {
		return "", fmt.Errorf("ffmpeg not found: %w", err)
	}

	cacheDir := filepath.Join(config.GetUserDataPath(), "WearCache")
	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		return "", fmt.Errorf("create WearCache dir: %w", err)
	}

	cachedPath := filepath.Join(cacheDir, songID+".m4a")

	// Fast path: cache hit
	if _, err := os.Stat(cachedPath); err == nil {
		return cachedPath, nil
	}

	// Serialise concurrent requests for the same song
	mu, _ := transcodeOnce.LoadOrStore(songID, &sync.Mutex{})
	lock := mu.(*sync.Mutex)
	lock.Lock()
	defer lock.Unlock()

	// Re-check after acquiring the lock (another goroutine may have finished)
	if _, err := os.Stat(cachedPath); err == nil {
		return cachedPath, nil
	}

	// Transcode to a temp file, then atomically rename so a partial file
	// is never mistaken for a complete one.
	tmpPath := cachedPath + ".tmp"
	_ = os.Remove(tmpPath) // clean up any stale temp

	fmt.Printf("[Wear] Transcoding %s → m4a 128 kbps …\n", songID)
	start := time.Now()

	cmd := exec.Command(ffmpegPath,
		"-i", inputPath,
		"-c:a", "aac",        // AAC codec (native to watchOS)
		"-b:a", "128k",       // 128 kbps — good balance for Watch speaker / earbuds
		"-ar", "44100",       // 44.1 kHz sample rate
		"-ac", "2",           // stereo
		"-vn",                // strip video / embedded artwork (saves space)
		"-map_metadata", "0", // preserve title/artist/album tags
		"-f", "mp4",          // explicit container format (temp file has .tmp extension)
		"-y",                 // overwrite output without asking
		tmpPath,
	)

	if out, err := cmd.CombinedOutput(); err != nil {
		_ = os.Remove(tmpPath)
		return "", fmt.Errorf("ffmpeg exit: %w\n%s", err, string(out))
	}

	if err := os.Rename(tmpPath, cachedPath); err != nil {
		_ = os.Remove(tmpPath)
		return "", fmt.Errorf("rename tmp→cache: %w", err)
	}

	orig, _ := os.Stat(inputPath)
	cached, _ := os.Stat(cachedPath)
	origMB := float64(0)
	cacheMB := float64(0)
	if orig != nil {
		origMB = float64(orig.Size()) / 1024 / 1024
	}
	if cached != nil {
		cacheMB = float64(cached.Size()) / 1024 / 1024
	}
	fmt.Printf("[Wear] Transcoded %s in %.1fs  (%.1f MB → %.1f MB)\n",
		songID, time.Since(start).Seconds(), origMB, cacheMB)

	return cachedPath, nil
}

// locateFfmpeg finds the ffmpeg binary on macOS (Homebrew paths + PATH).
func locateFfmpeg() (string, error) {
	// Check well-known Homebrew locations first so we don't rely on PATH alone
	for _, candidate := range []string{
		"/opt/homebrew/bin/ffmpeg", // Apple Silicon
		"/usr/local/bin/ffmpeg",    // Intel
	} {
		if _, err := os.Stat(candidate); err == nil {
			return candidate, nil
		}
	}
	// Fall back to PATH lookup
	return exec.LookPath("ffmpeg")
}

// ─── Helpers ────────────────────────────────────────────────────────────────

// findSongPathByID scans the library JSON store and returns the file path for
// the song with the given UUID.
func findSongPathByID(id string) string {
	raw, err := store.Instance.Load("library")
	if err != nil || raw == nil {
		return ""
	}
	library, ok := raw.([]interface{})
	if !ok {
		return ""
	}
	for _, item := range library {
		song, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		if song["id"] == id {
			path, _ := song["path"].(string)
			return path
		}
	}
	return ""
}

// computeArtworkID returns the hex SHA256 hash used as the artwork filename.
// It mirrors the naming convention used by internal/scanner/artwork.go.
func computeArtworkID(albumArtist, album string) string {
	key := fmt.Sprintf("%s---%s", albumArtist, album)
	h := sha256.Sum256([]byte(key))
	return fmt.Sprintf("%x", h)
}

// findArtworkByID looks for {id}.jpg, {id}.png, or {id}.webp in artworksDir.
func findArtworkByID(id, artworksDir string) string {
	for _, ext := range []string{".jpg", ".jpeg", ".png", ".webp"} {
		candidate := filepath.Join(artworksDir, id+ext)
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return ""
}

func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(v); err != nil {
		http.Error(w, "JSON encode error", http.StatusInternalServerError)
	}
}

// corsMiddleware adds permissive CORS headers so that LAN clients can reach
// the server without browser/WebView restrictions.
func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// ─── Wails-exposed methods ──────────────────────────────────────────────────

// GetWearAddress returns the LAN address shown to the user in Settings.
func (a *App) GetWearAddress() string {
	return GetWearServerAddress()
}
