package main

import (
	"net/http"
	"path/filepath"
	"strings"

	"ux-music-sidecar/internal/lyrics"
	"ux-music-sidecar/internal/playlist"
	"ux-music-sidecar/internal/store"
)

// wearLyricsHandler serves `GET /wear/lyrics?id={songId}` with JSON
// `{ "found": true, "type": "lrc"|"txt", "content": "..." }` or `{ "found": false }`.
func wearLyricsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET only", http.StatusMethodNotAllowed)
		return
	}
	id := strings.TrimSpace(r.URL.Query().Get("id"))
	if id == "" {
		http.Error(w, "missing id", http.StatusBadRequest)
		return
	}
	song, ok := wearLibrarySongByID(id)
	if !ok {
		writeJSON(w, map[string]interface{}{"found": false})
		return
	}
	title, _ := song["title"].(string)
	path, _ := song["path"].(string)
	candidates := make([]string, 0, 3)
	if t := strings.TrimSpace(title); t != "" {
		candidates = append(candidates, t)
	}
	if base := filepath.Base(path); base != "" {
		stem := strings.TrimSuffix(base, filepath.Ext(base))
		if stem != "" {
			candidates = append(candidates, stem)
		}
	}
	seen := make(map[string]struct{})
	for _, cand := range candidates {
		cand = strings.TrimSpace(cand)
		if cand == "" {
			continue
		}
		if _, dup := seen[cand]; dup {
			continue
		}
		seen[cand] = struct{}{}
		res, err := lyrics.FindLyrics(cand)
		if err != nil || res == nil {
			continue
		}
		typ := res["type"]
		content := res["content"]
		if strings.TrimSpace(content) == "" {
			continue
		}
		writeJSON(w, map[string]interface{}{
			"found":   true,
			"type":    typ,
			"content": content,
		})
		return
	}
	writeJSON(w, map[string]interface{}{"found": false})
}

// wearPlaylistsHandler serves `GET /wear/playlists` as a JSON array of
// `{ "name": string, "songIds": [...], "pathsNotInLibrary"?: [...] }`.
func wearPlaylistsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "GET only", http.StatusMethodNotAllowed)
		return
	}
	names, err := playlist.GetAllPlaylists()
	if err != nil || len(names) == 0 {
		writeJSON(w, []interface{}{})
		return
	}
	pathToID := buildPathToIDMap()
	out := make([]map[string]interface{}, 0, len(names))
	for _, name := range names {
		paths, err := playlist.GetPlaylistSongs(name)
		if err != nil {
			continue
		}
		ids := make([]string, 0, len(paths))
		var unmatched []string
		for _, p := range paths {
			if id, ok := wearPlaylistPathToSongID(pathToID, p); ok {
				ids = append(ids, id)
			} else {
				unmatched = append(unmatched, p)
			}
		}
		entry := map[string]interface{}{
			"name":    name,
			"songIds": ids,
		}
		if len(unmatched) > 0 {
			entry["pathsNotInLibrary"] = unmatched
		}
		out = append(out, entry)
	}
	writeJSON(w, out)
}

func wearPlaylistPathToSongID(pathToID map[string]string, playlistPath string) (string, bool) {
	if pathToID == nil || playlistPath == "" {
		return "", false
	}
	candidates := []string{
		playlistPath,
		filepath.Clean(playlistPath),
		filepath.ToSlash(playlistPath),
		filepath.Clean(filepath.ToSlash(playlistPath)),
	}
	seen := make(map[string]struct{})
	for _, k := range candidates {
		k = strings.TrimSpace(k)
		if k == "" {
			continue
		}
		if _, d := seen[k]; d {
			continue
		}
		seen[k] = struct{}{}
		if id, ok := pathToID[k]; ok {
			return id, true
		}
	}
	return "", false
}

// wearLibrarySongByID returns the raw library map for a song id (or path-shaped legacy id).
func wearLibrarySongByID(id string) (map[string]interface{}, bool) {
	raw, err := store.Instance.Load("library")
	if err != nil || raw == nil {
		return nil, false
	}
	library, ok := raw.([]interface{})
	if !ok {
		return nil, false
	}
	try := func(candidate string) (map[string]interface{}, bool) {
		if candidate == "" {
			return nil, false
		}
		for _, item := range library {
			song, ok := item.(map[string]interface{})
			if !ok {
				continue
			}
			sid, _ := song["id"].(string)
			if sid == candidate {
				return song, true
			}
			spath, _ := song["path"].(string)
			if spath != "" && spath == candidate {
				return song, true
			}
		}
		return nil, false
	}
	if s, ok := try(id); ok {
		return s, true
	}
	if !strings.HasPrefix(id, "/") {
		if s, ok := try("/" + id); ok {
			return s, true
		}
	}
	return nil, false
}
