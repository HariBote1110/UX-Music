package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"

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

	http.ServeFile(w, r, filePath)
}

func wearArtworkHandler(w http.ResponseWriter, r *http.Request) {
	songID := strings.TrimPrefix(r.URL.Path, "/wear/artwork/")
	if songID == "" {
		http.Error(w, "missing song ID", http.StatusBadRequest)
		return
	}

	// Artworks are stored as {uuid}.jpg in the Artworks directory
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
