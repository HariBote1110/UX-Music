package main

import (
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/server"
)

func newAssetHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		escapedPath := r.URL.EscapedPath()
		if strings.HasPrefix(path, "/safe-artwork/") {
			filename := strings.TrimPrefix(escapedPath, "/safe-artwork/")
			fullPath := server.ResolveArtworkPath(filename)
			if fullPath == "" {
				http.Error(w, "Forbidden", http.StatusForbidden)
				return
			}
			http.ServeFile(w, r, fullPath)
			return
		}
		if strings.HasPrefix(escapedPath, "/safe-media/") {
			relPath := strings.TrimPrefix(escapedPath, "/safe-media/")
			fullPath, ok := resolveRegisteredSafeMediaPath(relPath)
			if !ok {
				http.Error(w, "Forbidden", http.StatusForbidden)
				return
			}
			if _, err := os.Stat(fullPath); err != nil {
				fmt.Printf("[Wails] Media file not found: %s (error: %v)\n", fullPath, err)
				http.NotFound(w, r)
				return
			}
			http.ServeFile(w, r, fullPath)
			return
		}
		http.NotFound(w, r)
	})
}

func resolveRegisteredSafeMediaPath(raw string) (string, bool) {
	candidate, ok := decodeSafeMediaPath(raw)
	if !ok {
		return "", false
	}
	library, err := store.Instance.LoadSlice("library")
	if err != nil {
		return "", false
	}
	cleanCandidate := filepath.Clean(candidate)
	for _, item := range library {
		song, ok := item.(map[string]interface{})
		if !ok {
			continue
		}
		path, ok := song["path"].(string)
		if !ok || strings.TrimSpace(path) == "" {
			continue
		}
		if filepath.Clean(path) == cleanCandidate {
			return cleanCandidate, true
		}
	}
	return "", false
}

func decodeSafeMediaPath(raw string) (string, bool) {
	decoded, err := url.PathUnescape(strings.TrimSpace(raw))
	if err != nil {
		return "", false
	}
	decoded = strings.ReplaceAll(decoded, "\\", "/")
	decoded = strings.TrimLeft(decoded, "/")
	if decoded == "" {
		return "", false
	}
	candidate := filepath.Clean(string(filepath.Separator) + decoded)
	if candidate == string(filepath.Separator) || strings.Contains(candidate, "\x00") {
		return "", false
	}
	return candidate, filepath.IsAbs(candidate)
}
