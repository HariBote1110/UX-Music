package main

import (
	"context"
	"encoding/json"
	"fmt"
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
)

const wearServerPort = "8765"

// WearServer holds the HTTP server for the /wear/ endpoints.
type WearServer struct {
	server *http.Server
}

// StartWearServer starts the LAN HTTP server that serves the /wear/ API.
// It binds to 0.0.0.0:8765 so that iPhone and Apple Watch on the same
// network can reach the UX Music library.
func StartWearServer(ctx context.Context) *WearServer {
	mux := http.NewServeMux()
	mux.HandleFunc("/wear/ping", wearPingHandler)
	mux.HandleFunc("/wear/songs", wearSongsHandler)
	mux.HandleFunc("/wear/file/", wearFileHandler)
	mux.HandleFunc("/wear/artwork/", wearArtworkHandler)

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

	return &WearServer{server: srv}
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
		clean := make(map[string]interface{}, len(song))
		for k, v := range song {
			if k == "artwork" {
				continue
			}
			clean[k] = v
		}
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
	songID := strings.TrimPrefix(r.URL.Path, "/wear/artwork/")
	if songID == "" {
		http.Error(w, "missing song ID", http.StatusBadRequest)
		return
	}

	artworksDir := filepath.Join(config.GetUserDataPath(), "Artworks")
	artworkPath := findArtworkByID(songID, artworksDir)
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
		w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
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
