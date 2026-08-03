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
	"ux-music-sidecar/internal/uxsync"

	"github.com/skip2/go-qrcode"
	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

const lanServerPort = "8765"

const pairingURLScheme = "uxmusic"

// LANServer holds the HTTP server for the unified LAN API (/v1/remote/*,
// /v1/sync/*, /v1/identity, /v1/pairing/*).
type LANServer struct {
	server   *http.Server
	app      *App
	syncMDNS *uxsync.MDNSAdvertisement
	syncInfo uxsync.MDNSAdvertiseInfo
}

// StartLANServer starts the LAN HTTP server that serves the unified /v1/ API.
// It binds to 0.0.0.0:8765 so that iPhone, Apple Watch, and other desktops
// on the same network can reach the UX Music library.
func StartLANServer(ctx context.Context, app *App) *LANServer {
	ls := &LANServer{app: app}

	srv := &http.Server{
		Addr:    "0.0.0.0:" + lanServerPort,
		Handler: NewLANHTTPHandler(app),
	}

	go func() {
		fmt.Printf("[LAN] HTTP server listening on :%s\n", lanServerPort)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			fmt.Printf("[LAN] Server error: %v\n", err)
		}
	}()

	go func() {
		<-ctx.Done()
		if ls.syncMDNS != nil {
			ls.syncMDNS.Shutdown()
		}
		_ = srv.Close()
	}()

	ls.server = srv
	ls.startSyncMDNS()
	return ls
}

func NewLANHTTPHandler(app *App) http.Handler {
	ls := &LANServer{app: app}
	mux := http.NewServeMux()
	registerPairingRoutes(mux)
	registerRemoteRoutes(mux, ls)
	registerSyncRoutes(mux, app)
	return corsMiddleware(deviceAuthMiddleware(mux))
}

func registerRemoteRoutes(mux *http.ServeMux, ls *LANServer) {
	mux.HandleFunc("/v1/remote/songs", remoteSongsHandler)
	mux.HandleFunc("/v1/remote/lyrics", remoteLyricsHandler)
	mux.HandleFunc("/v1/remote/playlists", remotePlaylistsHandler)
	mux.HandleFunc("/v1/remote/file", remoteFileHandler)
	mux.HandleFunc("/v1/remote/file/", remoteFileHandler)
	mux.HandleFunc("/v1/remote/artwork/", remoteArtworkHandler)
	mux.HandleFunc("/v1/remote/loudness", ls.remoteLoudnessHandler)
	mux.HandleFunc("/v1/remote/state", ls.remoteStateHandler)
	mux.HandleFunc("/v1/remote/command", ls.remoteCommandHandler)
}

// GetLANServerAddress returns the LAN address of this machine for display in the UI.
func GetLANServerAddress() string {
	addrs := lanIPv4Addresses()
	if len(addrs) == 0 {
		return "localhost:" + lanServerPort
	}
	return addrs[0] + ":" + lanServerPort
}

// lanIPv4Addresses returns every non-loopback, non-link-local IPv4 address bound to this
// machine's network interfaces, in a stable order. A machine with several NICs (Wi-Fi,
// Ethernet, Tailscale, …) can have multiple LAN-reachable addresses at once, and only the
// mobile client — not the desktop — knows which one a given peer can actually reach. All of
// them are therefore surfaced (via BuildPairingURL's hosts= param) so the client can probe
// each candidate itself, mirroring the mDNS discovery failover in RemoteConnectionResolver.
func lanIPv4Addresses() []string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return nil
	}
	var out []string
	for _, addr := range addrs {
		ipNet, ok := addr.(*net.IPNet)
		if !ok || ipNet.IP.IsLoopback() || ipNet.IP.IsLinkLocalUnicast() {
			continue
		}
		if v4 := ipNet.IP.To4(); v4 != nil {
			out = append(out, v4.String())
		}
	}
	return out
}

// ─── Handlers ───────────────────────────────────────────────────────────────

func remoteSongsHandler(w http.ResponseWriter, r *http.Request) {
	// Strip artwork blobs before sending to save bandwidth
	library, err := store.Instance.LoadSlice("library")
	if err != nil || len(library) == 0 {
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
		clean["artworkId"] = artworkIDForRemoteSong(song)
		stripped = append(stripped, clean)
	}

	ensureRemoteTrackOrder(stripped)

	writeJSON(w, stripped)
}

func remoteFileHandler(w http.ResponseWriter, r *http.Request) {
	songID := strings.TrimSpace(r.URL.Query().Get("id"))
	if songID == "" {
		songID = strings.TrimPrefix(r.URL.Path, "/v1/remote/file/")
		songID = strings.TrimPrefix(songID, "/")
		if decoded, err := url.PathUnescape(songID); err == nil {
			songID = decoded
		}
	}
	if songID == "" {
		writeAPIError(w, "missing song ID", http.StatusBadRequest)
		return
	}
	fmt.Printf("[Remote] GET /v1/remote/file id=%q from %s\n", songID, r.RemoteAddr)

	filePath := findSongPathByID(songID)
	if filePath == "" {
		http.NotFound(w, r)
		return
	}

	// Security: ensure the file path is absolute and exists
	if !filepath.IsAbs(filePath) {
		writeAPIError(w, "Forbidden", http.StatusForbidden)
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
		fmt.Printf("[Remote] Transcode failed for %s: %v — serving original\n", songID, err)
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

func remoteArtworkHandler(w http.ResponseWriter, r *http.Request) {
	// Accept either /v1/remote/artwork/{artworkId} (hash) or
	// a query param ?id={artworkId} for clients that cannot encode slashes.
	artworkID := r.URL.Query().Get("id")
	if artworkID == "" {
		artworkID = strings.TrimPrefix(r.URL.Path, "/v1/remote/artwork/")
	}
	if artworkID == "" {
		writeAPIError(w, "missing artwork ID", http.StatusBadRequest)
		return
	}

	artworksDir := filepath.Join(config.GetUserDataPath(), "Artworks")

	// Security: artworkID must be a plain hex string (no path separators).
	if strings.ContainsAny(artworkID, "/\\") {
		writeAPIError(w, "Forbidden", http.StatusForbidden)
		return
	}

	artworkPath := findArtworkByID(artworkID, artworksDir)
	if artworkPath == "" {
		http.NotFound(w, r)
		return
	}

	// Security: must be inside artworksDir
	if !strings.HasPrefix(artworkPath, artworksDir) {
		writeAPIError(w, "Forbidden", http.StatusForbidden)
		return
	}

	http.ServeFile(w, r, artworkPath)
}

// ─── Remote Companion Handlers ──────────────────────────────────────────────

// remoteLoudnessHandler returns a map of songID → LUFS loudness value.
// Remote clients use this to apply volume normalisation during local playback.
func (ls *LANServer) remoteLoudnessHandler(w http.ResponseWriter, r *http.Request) {
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

// remoteStateHandler returns the current desktop playback state.
func (ls *LANServer) remoteStateHandler(w http.ResponseWriter, r *http.Request) {
	status := ls.app.AudioGetStatus()

	// Include current track metadata from OS media state
	ls.app.mediaStateMu.Lock()
	status["title"] = ls.app.mediaTitle
	status["artist"] = ls.app.mediaArtist
	status["album"] = ls.app.mediaAlbum
	ls.app.mediaStateMu.Unlock()

	writeJSON(w, status)
}

// remoteCommandHandler accepts remote playback commands from mobile clients.
// Supported actions: toggle, play, pause, stop, next, prev, seek.
func (ls *LANServer) remoteCommandHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeAPIError(w, "POST required", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, 1024))
	if err != nil {
		writeAPIError(w, "read body failed", http.StatusBadRequest)
		return
	}
	defer r.Body.Close()

	var cmd struct {
		Action string  `json:"action"`
		Value  float64 `json:"value,omitempty"`
	}
	if err := json.Unmarshal(body, &cmd); err != nil {
		writeAPIError(w, "invalid JSON", http.StatusBadRequest)
		return
	}

	var cmdErr error
	switch cmd.Action {
	case "toggle":
		if ls.app.AudioIsPlaying() {
			cmdErr = ls.app.AudioPause()
		} else {
			cmdErr = ls.app.AudioResume()
		}
	case "play":
		cmdErr = ls.app.AudioResume()
	case "pause":
		cmdErr = ls.app.AudioPause()
	case "stop":
		cmdErr = ls.app.AudioStop()
	case "seek":
		cmdErr = ls.app.AudioSeek(cmd.Value)
	case "next", "prev":
		// Queue management lives in the Wails frontend; delegate via event
		if ls.app.ctx != nil {
			wailsRuntime.EventsEmit(ls.app.ctx, "remote-command", cmd.Action)
		}
	default:
		writeAPIError(w, "unknown action", http.StatusBadRequest)
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
	library, err := store.Instance.LoadSlice("library")
	if err != nil || len(library) == 0 {
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

	cacheDir := filepath.Join(config.GetUserDataPath(), "RemoteCache")
	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		return "", fmt.Errorf("create transcode cache dir: %w", err)
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

	fmt.Printf("[Remote] Transcoding %s → m4a 128 kbps …\n", songID)
	start := time.Now()

	cmd := exec.Command(ffmpegPath,
		"-i", inputPath,
		"-c:a", "aac", // AAC codec (native to watchOS)
		"-b:a", "128k", // 128 kbps — good balance for Watch speaker / earbuds
		"-ar", "44100", // 44.1 kHz sample rate
		"-ac", "2", // stereo
		"-vn",                // strip video / embedded artwork (saves space)
		"-map_metadata", "0", // preserve title/artist/album tags
		"-f", "mp4", // explicit container format (temp file has .tmp extension)
		"-y", // overwrite output without asking
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
	fmt.Printf("[Remote] Transcoded %s in %.1fs  (%.1f MB → %.1f MB)\n",
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
	library, err := store.Instance.LoadSlice("library")
	if err != nil || len(library) == 0 {
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
	// Old clients put path-like ids in the URL path; a leading "/" was lost after "/v1/remote/file/".
	if !strings.HasPrefix(id, "/") {
		if p := tryMatch("/" + id); p != "" {
			return p
		}
	}
	return ""
}

// artworkIDForRemoteSong returns the hex filename stem served by /v1/remote/artwork/{id}.
func artworkIDForRemoteSong(song map[string]interface{}) string {
	if id := artworkIDFromStoredArtwork(song["artwork"]); id != "" {
		return id
	}
	return computeArtworkIDForRemoteFallback(song)
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

// computeArtworkIDForRemoteFallback mirrors internal/scanner/artwork.go tag fallbacks
// when no artwork object is present (e.g. never extracted).
func computeArtworkIDForRemoteFallback(song map[string]interface{}) string {
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
		writeAPIError(w, "JSON encode error", http.StatusInternalServerError)
	}
}

// corsMiddleware adds permissive CORS headers so that LAN clients can reach
// the server without browser/WebView restrictions.
func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// BuildPairingURL returns a mobile deep link for QR pairing
// (uxmusic://pair?host=&hosts=&port=&secret=). The secret is a fresh one-time value;
// the client redeems it via POST /v1/pairing/redeem to receive its own
// device-specific auth token — no long-lived token is embedded in the QR code.
//
// hosts= carries every LAN IPv4 address of this machine (comma-separated, primary first) so a
// mobile client on a different subnet/NIC than the one host= happens to name can still find a
// reachable address, the same way mDNS discovery already fails over across candidates. host= is
// kept for backwards compatibility with older QR readers.
func BuildPairingURL() string {
	addrs := lanIPv4Addresses()
	host, port := "localhost", lanServerPort
	if len(addrs) > 0 {
		host = addrs[0]
	}
	q := url.Values{}
	q.Set("host", host)
	q.Set("port", port)
	if len(addrs) > 0 {
		q.Set("hosts", strings.Join(addrs, ","))
	}
	q.Set("secret", newPairingRedeemSecret())
	return pairingURLScheme + "://pair?" + q.Encode()
}

// ─── Wails-exposed methods ──────────────────────────────────────────────────

// GetLANAddress returns the LAN address shown to the user in Settings.
func (a *App) GetLANAddress() string {
	return GetLANServerAddress()
}

// GetPairingURL returns the uxmusic:// URL encoded in the pairing QR code.
func (a *App) GetPairingURL() string {
	return BuildPairingURL()
}

// GetPairingQRDataURL returns a data:image/png;base64,… URL for the pairing QR code.
func (a *App) GetPairingQRDataURL() (string, error) {
	payload := BuildPairingURL()
	png, err := qrcode.Encode(payload, qrcode.Medium, 256)
	if err != nil {
		return "", err
	}
	return "data:image/png;base64," + base64.StdEncoding.EncodeToString(png), nil
}
