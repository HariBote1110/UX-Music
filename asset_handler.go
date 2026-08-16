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
			filename := strings.TrimPrefix(path, "/safe-artwork/")
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
	if decoded == "" {
		return "", false
	}
	hasDriveLetter := hasWindowsDriveLetterPath(decoded)
	// library.json may have been written by a POSIX (macOS/Linux) build, so
	// a leading "/" without a drive letter is a legitimate absolute path
	// even when this process is running on Windows.
	posixRooted := !hasDriveLetter && strings.HasPrefix(decoded, "/")
	var candidate string
	if filepath.VolumeName(decoded) != "" || posixRooted || hasDriveLetter {
		candidate = filepath.Clean(decoded)
	} else {
		candidate = filepath.Clean(string(filepath.Separator) + decoded)
	}
	if candidate == string(filepath.Separator) || strings.Contains(candidate, "\x00") {
		return "", false
	}
	// filepath.IsAbs is drive-letter-strict on Windows: a POSIX-rooted path
	// with no drive letter (e.g. "\Users\yuki\Music\song.mp4" after
	// filepath.Clean) is reported as *not* absolute there, even though it is
	// a legitimate absolute path key coming from a macOS-created library.
	// Accept it explicitly via posixRooted so cross-platform libraries keep
	// resolving regardless of which OS is currently serving them.
	return candidate, filepath.IsAbs(candidate) || hasDriveLetter || posixRooted
}

func hasWindowsDriveLetterPath(path string) bool {
	if len(path) < 3 || path[1] != ':' || path[2] != '/' {
		return false
	}
	drive := path[0]
	return (drive >= 'A' && drive <= 'Z') || (drive >= 'a' && drive <= 'z')
}
