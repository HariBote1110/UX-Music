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
	"strconv"
	"strings"
	"sync"
	"time"

	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/internal/uxsync"

	"github.com/skip2/go-qrcode"
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
	registerLocalRoutes(mux)
	return corsMiddleware(deviceAuthMiddleware(mux))
}

func registerRemoteRoutes(mux *http.ServeMux, ls *LANServer) {
	mux.HandleFunc("/v1/remote/songs", remoteSongsHandler)
	mux.HandleFunc("/v1/remote/lyrics", remoteLyricsHandler)
	mux.HandleFunc("/v1/remote/playlists", remotePlaylistsHandler)
	mux.HandleFunc("/v1/remote/situation-playlists", remoteSituationPlaylistsHandler)
	mux.HandleFunc("/v1/remote/youtube/resolve", remoteYouTubeResolveHandler)
	mux.HandleFunc("/v1/remote/youtube/add", ls.remoteYouTubeAddHandler)
	mux.HandleFunc("/v1/remote/file", remoteFileHandler)
	mux.HandleFunc("/v1/remote/file/", remoteFileHandler)
	mux.HandleFunc("/v1/remote/artwork/", remoteArtworkHandler)
	mux.HandleFunc("/v1/remote/loudness", ls.remoteLoudnessHandler)
	mux.HandleFunc("/v1/remote/state", ls.remoteStateHandler)
	mux.HandleFunc("/v1/remote/relay", remoteRelayHandler)
	mux.HandleFunc("/v1/remote/command", ls.remoteCommandHandler)
	mux.HandleFunc("/v1/remote/play-event", ls.app.remotePlayEventHandler)
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
		// Additive: tells clients whether GET /v1/remote/file/{id} will actually
		// serve audio. Entries registered with type:"youtube" (see buildStreamingSong
		// in app_youtube.go) hold a video URL in "path", not a local file — TV/mobile
		// clients must route those through embed/relay playback instead of expecting
		// a downloadable file. Everything else (type:"local" or the unset legacy
		// default) has a real file on disk.
		clean["hasLocalAudio"] = songHasLocalAudio(song)
		stripped = append(stripped, clean)
	}

	stripped = dedupRemoteSongs(stripped)
	ensureRemoteTrackOrder(stripped)

	writeJSON(w, stripped)
}

// songHasLocalAudio reports whether a library entry has a playable local
// audio file (true) or is an embed/relay-only YouTube link registered via
// buildStreamingSong (type:"youtube", "path" holds a video URL, not a file
// path). Entries with type:"local" or no "type" at all (the legacy default,
// predating this field) have a real file on disk.
func songHasLocalAudio(song map[string]interface{}) bool {
	typ, _ := song["type"].(string)
	return typ != "youtube"
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

	if song, ok := remoteLibrarySongByID(songID); ok && !songHasLocalAudio(song) {
		writeAPIErrorWithCode(w, "no_local_audio", "this song has no local audio file (embed/relay only)", http.StatusNotFound)
		return
	}

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

	// Live streaming transcode: a client with no cached copy (typically a TV
	// with limited local storage) can start playback in well under a second
	// via a live ffmpeg encode, while separately downloading the original
	// through a plain (no ?stream=) request for future offline playback.
	// Range requests are not meaningful here (there is no seekable
	// Content-Length — the response is chunked) and are ignored rather than
	// honoured.
	if strings.EqualFold(strings.TrimSpace(r.URL.Query().Get("stream")), "aac") {
		serveFileStreamAAC(w, r, filePath)
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

	// Try to serve a transcoded AAC m4a at the requested bitrate (128 kbps by
	// default — the Watch-oriented default that also keeps old clients working).
	// Falls back to the original file if ffmpeg is unavailable or fails.
	rawBitrate := r.URL.Query().Get("bitrate")
	bitrateKbps := parseAACBitrateQueryParam(rawBitrate)
	if rawBitrate != "" && bitrateKbps == defaultAACBitrateKbps && rawBitrate != fmt.Sprintf("%d", defaultAACBitrateKbps) {
		fmt.Printf("[Remote] Invalid bitrate param %q for %s — falling back to %d kbps\n", rawBitrate, songID, defaultAACBitrateKbps)
	}
	cachedPath, err := getOrTranscode(songID, filePath, bitrateKbps)
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
	status["songId"] = ls.app.mediaSongID
	status["artworkId"] = ls.app.mediaArtworkID
	ls.app.mediaStateMu.Unlock()

	// Additive relay block for Phase 3-3 (YouTube 音声中継). Existing fields
	// are untouched so older clients ignoring unknown keys keep working.
	relayActive, relayTitle, relayThumbnail := remoteRelay.State()
	status["relay"] = map[string]interface{}{
		"active":    relayActive,
		"title":     relayTitle,
		"thumbnail": relayThumbnail,
	}

	// Additive: true while the desktop's own speaker output is silenced for
	// a remote-initiated playback session (see MarkNextPlaybackRemoteInitiated
	// in app_audio.go). The relay above is unaffected either way.
	status["localMuted"] = ls.app.AudioIsLocalMuted()

	// Additive: sidecar directive telling this caller whether it is the
	// current fullscreen sidecar target (see app_sidecar.go). Always
	// present so older clients that ignore unknown keys keep working.
	status["sidecar"] = ls.app.sidecarDirectiveFor(deviceIDFromContext(r.Context()))

	// During an embed (YouTube IFrame) session the Go audio.Player above is
	// idle — AudioGetStatus's position/duration/playing would read 0/0/false
	// — while the renderer's IFrame player is what is actually sounding.
	// Prefer the renderer's own report (ReportEmbedPlaybackState) so TV/
	// mobile clients' seek UI reflects the embed instead. Additive: only
	// overrides these three keys, and only while both an embed session is
	// active and at least one report has arrived for it.
	if relayActive {
		if pos, dur, playing, active := currentEmbedPlaybackReport.Get(); active {
			status["position"] = pos
			status["duration"] = dur
			status["playing"] = playing
			status["paused"] = !playing
		}
	}

	writeJSON(w, status)
}

// embedSessionActive reports whether the desktop is currently playing a
// YouTube official embed (renderer's IFrame player, relayed to
// GET /v1/remote/relay) rather than a local file through the Go
// audio.Player. It reuses remoteRelay's own active flag — set by
// NotifyYouTubePlaybackState when the renderer's playEmbed() starts/ends a
// session — instead of tracking a second, parallel piece of state.
func embedSessionActive() bool {
	active, _, _ := remoteRelay.State()
	return active
}

// remoteCommandHandler accepts remote playback commands from mobile clients.
// Supported actions: toggle, play, pause, stop, next, prev, seek, play-song.
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
		SongID string  `json:"songId,omitempty"`
	}
	if err := json.Unmarshal(body, &cmd); err != nil {
		writeAPIError(w, "invalid JSON", http.StatusBadRequest)
		return
	}

	// While a YouTube official embed session is active (renderer notified Go
	// via NotifyYouTubePlaybackState → remoteRelay.active), the Go
	// audio.Player is not what is actually sounding — the renderer's IFrame
	// player is. Transport commands must therefore be routed to the
	// renderer instead of driving a Go player nobody is listening to.
	// remote-command's plain-string "next"/"prev" is untouched: queue
	// advancement already lives in the renderer (playback-manager.ts
	// playNextSong/playPrevSong), which re-enters play()'s own embed/local
	// routing per song regardless of whether the outgoing song was an embed.
	if embedSessionActive() {
		switch cmd.Action {
		case "toggle", "play", "pause", "stop", "seek":
			ls.app.emit("remote-embed-command", map[string]interface{}{
				"action": cmd.Action,
				"value":  cmd.Value,
			})
			writeJSON(w, map[string]interface{}{"ok": true})
			return
		}
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
		// Queue management lives in the Wails frontend by default;
		// delegate via event — UNLESS the Go queue has been activated
		// (something called QueueSet; see app_queue.go), in which case Go
		// owns next/prev entirely and there is no renderer queue to
		// delegate to.
		if ls.app.ensureQueue().Active() {
			if cmd.Action == "next" {
				cmdErr = ls.app.QueueNext()
			} else {
				cmdErr = ls.app.QueuePrev()
			}
		} else {
			ls.app.emit("remote-command", cmd.Action)
		}
	case "play-song":
		// Playback needs the renderer (local files play via <audio>, YouTube
		// entries route through the official embed which then drives the LAN
		// relay), so this action is meaningless without a Wails runtime.
		if CurrentServerMode() != ModeGUI {
			writeAPIErrorWithCode(w, "gui_required", "play-song requires the desktop app to be running in GUI mode", http.StatusConflict)
			return
		}
		songID := strings.TrimSpace(cmd.SongID)
		if songID == "" {
			writeAPIError(w, "missing songId", http.StatusBadRequest)
			return
		}
		if _, ok := remoteLibrarySongByID(songID); !ok {
			writeAPIError(w, "song not found", http.StatusNotFound)
			return
		}
		// A dedicated event (rather than folding this into the plain-string
		// "remote-command" used by next/prev) keeps existing subscribers
		// unaffected: they still receive only a string, unchanged. Renderer
		// resolves songID against the already-loaded library state and
		// reuses the same play-entry path a user click would take.
		ls.app.emit("remote-play-song", songID)
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
// for the same song ID + bitrate do not launch multiple ffmpeg processes.
var transcodeOnce sync.Map // key: "songID|bitrate", value: *sync.Mutex

// defaultAACBitrateKbps is served when the client omits ?bitrate= or sends an
// invalid value. It matches the historical hard-coded rate, so old clients
// (and the Watch, which always requests this endpoint without ?bitrate=)
// keep working unchanged.
const defaultAACBitrateKbps = 128

// allowedAACBitratesKbps are the only bitrates the transcoder will produce.
var allowedAACBitratesKbps = map[int]bool{128: true, 192: true, 256: true, 320: true}

// normaliseAACBitrateKbps clamps an arbitrary integer to one of the allowed
// AAC bitrates, falling back to defaultAACBitrateKbps for anything else.
func normaliseAACBitrateKbps(kbps int) int {
	if allowedAACBitratesKbps[kbps] {
		return kbps
	}
	return defaultAACBitrateKbps
}

// parseAACBitrateQueryParam parses the raw "bitrate" query string value into
// an allowed AAC bitrate, defaulting on empty/invalid input. It never errors
// — callers should log separately if they want to surface a bad value.
func parseAACBitrateQueryParam(raw string) int {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return defaultAACBitrateKbps
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		return defaultAACBitrateKbps
	}
	return normaliseAACBitrateKbps(n)
}

// remoteLegacyTranscodeCacheStem returns the pre-bitrate-selection cache file
// stem (sha256 of songID only), used to detect and reuse caches written
// before this feature existed.
func remoteLegacyTranscodeCacheStem(songID string) string {
	return fmt.Sprintf("%x", sha256.Sum256([]byte(songID)))
}

// remoteTranscodeCacheStem returns the cache file stem for a given song +
// bitrate. songID may contain slashes (path-shaped legacy keys), so it must
// never be used directly as a path segment.
func remoteTranscodeCacheStem(songID string, bitrateKbps int) string {
	return fmt.Sprintf("%x_%d", sha256.Sum256([]byte(songID)), bitrateKbps)
}

// getOrTranscode returns the path to an AAC m4a transcoded at bitrateKbps for
// the given song. On first call it transcodes via ffmpeg and caches the
// result. On subsequent calls it returns the cached file immediately.
// Falls back to original if ffmpeg is not found or transcoding fails.
//
// Backward compatibility: for the default 128 kbps rate only, a pre-existing
// legacy cache file (written before per-bitrate caching existed) is reused
// as-is rather than being re-transcoded. New 128 kbps writes always use the
// bitrate-suffixed cache name.
func getOrTranscode(songID, inputPath string, bitrateKbps int) (string, error) {
	bitrateKbps = normaliseAACBitrateKbps(bitrateKbps)

	cacheDir := filepath.Join(config.GetUserDataPath(), "RemoteCache")
	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		return "", fmt.Errorf("create transcode cache dir: %w", err)
	}

	cacheStem := remoteTranscodeCacheStem(songID, bitrateKbps)
	cachedPath := filepath.Join(cacheDir, cacheStem+".m4a")

	// Legacy fallback: a pre-bitrate-selection cache at 128 kbps is reused as-is.
	if bitrateKbps == defaultAACBitrateKbps {
		legacyPath := filepath.Join(cacheDir, remoteLegacyTranscodeCacheStem(songID)+".m4a")
		if _, err := os.Stat(legacyPath); err == nil {
			return legacyPath, nil
		}
	}

	// Fast path: cache hit
	if _, err := os.Stat(cachedPath); err == nil {
		return cachedPath, nil
	}

	// Locate ffmpeg — common paths on macOS + PATH fallback
	ffmpegPath, err := locateFfmpeg()
	if err != nil {
		return "", fmt.Errorf("ffmpeg not found: %w", err)
	}

	// Serialise concurrent requests for the same song + bitrate
	lockKey := fmt.Sprintf("%s|%d", songID, bitrateKbps)
	mu, _ := transcodeOnce.LoadOrStore(lockKey, &sync.Mutex{})
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

	fmt.Printf("[Remote] Transcoding %s → m4a %d kbps …\n", songID, bitrateKbps)
	start := time.Now()

	cmd := exec.Command(ffmpegPath,
		"-i", inputPath,
		"-c:a", "aac", // AAC codec (native to watchOS)
		"-b:a", fmt.Sprintf("%dk", bitrateKbps),
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
		w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Device-Name")
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
