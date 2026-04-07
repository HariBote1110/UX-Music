package server

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/store"

	"github.com/skip2/go-qrcode"
	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

const wearServerPort = "8765"

const wearPairingURLScheme = "uxmusic"

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
	mux.HandleFunc("/wear/mobile", wearMobileMetaHandler)
	mux.HandleFunc("/wear/songs", wearSongsHandler)
	mux.HandleFunc("/wear/lyrics", wearLyricsHandler)
	mux.HandleFunc("/wear/playlists", wearPlaylistsHandler)
	mux.HandleFunc("/wear/file", wearFileHandler)
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
	// wearApi 2: mobile-oriented additions (original file source, /wear/mobile, etc.). Watch clients may ignore extra keys.
	writeJSON(w, map[string]interface{}{
		"version":  "0.1.0",
		"hostname": hostname,
		"wearApi":  2,
	})
}

// wearMobileMetaHandler documents endpoints for phone companion apps (full-quality audio, cached artwork on device, etc.).
func wearMobileMetaHandler(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]interface{}{
		"role":     "ux-music-companion",
		"wearApi":  2,
		"songs":    "/wear/songs",
		"file":     "/wear/file?id={songId}",
		"fileHint": "Add &source=original for library file without Watch transcoding (AAC 128k m4a). Omit for watch-optimised cache.",
		"artwork":  "/wear/artwork/?id={artworkId}",
		"loudness": "/wear/loudness",
		"lyrics":   "/wear/lyrics?id={songId}",
		"playlists": "/wear/playlists",
		"state":    "/wear/state",
		"command":  "/wear/command (POST JSON)",
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
		// Artwork files on disk are named from internal/scanner/artwork.go (hash of
		// tag-derived keys with artist fallbacks). The library JSON may normalise
		// album fields differently, so prefer the hash embedded in song["artwork"].full.
		clean["artworkId"] = artworkIDForWearSong(song)
		stripped = append(stripped, clean)
	}

	ensureWearTrackOrder(stripped)

	writeJSON(w, stripped)
}

func wearFileHandler(w http.ResponseWriter, r *http.Request) {
	songID := strings.TrimSpace(r.URL.Query().Get("id"))
	if songID == "" {
		songID = strings.TrimPrefix(r.URL.Path, "/wear/file/")
		songID = strings.TrimPrefix(songID, "/")
		if decoded, err := url.PathUnescape(songID); err == nil {
			songID = decoded
		}
	}
	if songID == "" {
		http.Error(w, "missing song ID", http.StatusBadRequest)
		return
	}
	fmt.Printf("[Wear] GET /wear/file id=%q from %s\n", songID, r.RemoteAddr)

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

	// Phone / full-quality: skip Watch transcoding (original bitrate and container).
	if strings.EqualFold(strings.TrimSpace(r.URL.Query().Get("source")), "original") {
		safeName := filepath.Base(filePath)
		if safeName == "" || safeName == "." {
			safeName = "track"
		}
		w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename=%q`, safeName))
		http.ServeFile(w, r, filePath)
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

	// Tell the client this is an m4a; basename only (songID may be a full path in legacy libraries).
	safeName := filepath.Base(filePath)
	if safeName == "" || safeName == "." {
		safeName = "track.m4a"
	} else if !strings.HasSuffix(strings.ToLower(safeName), ".m4a") {
		safeName += ".m4a"
	}
	w.Header().Set("Content-Disposition", fmt.Sprintf(`attachment; filename=%q`, safeName))
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

	// songID may contain slashes (path-shaped legacy keys); never use it as a path segment.
	cacheStem := fmt.Sprintf("%x", sha256.Sum256([]byte(songID)))
	cachedPath := filepath.Join(cacheDir, cacheStem+".m4a")

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
// the song with the given id (UUID or legacy path-shaped key).
func findSongPathByID(id string) string {
	raw, err := store.Instance.Load("library")
	if err != nil || raw == nil {
		return ""
	}
	library, ok := raw.([]interface{})
	if !ok {
		return ""
	}
	tryMatch := func(candidate string) string {
		for _, item := range library {
			song, ok := item.(map[string]interface{})
			if !ok {
				continue
			}
			sid, _ := song["id"].(string)
			if sid == candidate {
				path, _ := song["path"].(string)
				return path
			}
			// Rare: id field duplicated as path
			spath, _ := song["path"].(string)
			if spath != "" && spath == candidate {
				return spath
			}
		}
		return ""
	}
	if p := tryMatch(id); p != "" {
		return p
	}
	// Old clients put path-like ids in the URL path; a leading "/" was lost after "/wear/file/".
	if !strings.HasPrefix(id, "/") {
		if p := tryMatch("/" + id); p != "" {
			return p
		}
	}
	return ""
}

// artworkIDForWearSong returns the hex filename stem served by /wear/artwork/{id}.
func artworkIDForWearSong(song map[string]interface{}) string {
	if id := artworkIDFromStoredArtwork(song["artwork"]); id != "" {
		return id
	}
	return computeArtworkIDForWearFallback(song)
}

func artworkIDFromStoredArtwork(v interface{}) string {
	m, ok := v.(map[string]interface{})
	if !ok {
		return ""
	}
	full, ok := m["full"].(string)
	if !ok {
		return ""
	}
	return hashStemFromArtworkFilename(full)
}

func hashStemFromArtworkFilename(full string) string {
	full = strings.TrimSpace(full)
	if full == "" {
		return ""
	}
	full = strings.ReplaceAll(full, `\`, `/`)
	base := filepath.Base(full)
	ext := strings.ToLower(filepath.Ext(base))
	switch ext {
	case ".webp", ".jpg", ".jpeg", ".png":
	default:
		return ""
	}
	stem := strings.TrimSuffix(base, ext)
	if len(stem) != 64 {
		return ""
	}
	for i := 0; i < len(stem); i++ {
		c := stem[i]
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') {
			continue
		}
		return ""
	}
	return stem
}

// computeArtworkIDForWearFallback mirrors internal/scanner/artwork.go tag fallbacks
// when no artwork object is present (e.g. never extracted).
func computeArtworkIDForWearFallback(song map[string]interface{}) string {
	albumArtist, _ := song["albumartist"].(string)
	artist, _ := song["artist"].(string)
	album, _ := song["album"].(string)
	path, _ := song["path"].(string)

	aa := strings.TrimSpace(albumArtist)
	if aa == "" {
		aa = strings.TrimSpace(artist)
	}
	if aa == "" {
		aa = "Unknown Artist"
	}
	al := strings.TrimSpace(album)
	if al == "" {
		al = filepath.Base(path)
	}
	return computeArtworkID(aa, al)
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

func wearPairingURLFromParts(host, port string) string {
	q := url.Values{}
	q.Set("host", host)
	q.Set("port", port)
	return wearPairingURLScheme + "://pair?" + q.Encode()
}

// BuildWearPairingURL returns a mobile deep link for QR pairing (uxmusic://pair?host=…&port=…).
func BuildWearPairingURL() string {
	addr := GetWearServerAddress()
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return wearPairingURLFromParts(strings.TrimSpace(addr), wearServerPort)
	}
	return wearPairingURLFromParts(host, port)
}

// ─── Wails-exposed methods ──────────────────────────────────────────────────

// GetWearAddress returns the LAN address shown to the user in Settings.
func (a *App) GetWearAddress() string {
	return GetWearServerAddress()
}

// GetWearPairingURL returns the uxmusic:// URL encoded in the mobile pairing QR code.
func (a *App) GetWearPairingURL() string {
	return BuildWearPairingURL()
}

// GetWearPairingQRDataURL returns a data:image/png;base64,… URL for the pairing QR code.
func (a *App) GetWearPairingQRDataURL() (string, error) {
	payload := BuildWearPairingURL()
	png, err := qrcode.Encode(payload, qrcode.Medium, 256)
	if err != nil {
		return "", err
	}
	return "data:image/png;base64," + base64.StdEncoding.EncodeToString(png), nil
}
