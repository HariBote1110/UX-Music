package server

import (
	"net/http"
	"path/filepath"
	"strings"

	"ux-music-sidecar/internal/lyrics"
	"ux-music-sidecar/internal/pathutil"
	"ux-music-sidecar/internal/playlist"
	"ux-music-sidecar/internal/store"
)

// remoteLyricsHandler serves `GET /v1/remote/lyrics?id={songId}` with JSON
// `{ "found": true, "type": "lrc"|"txt", "content": "..." }` or `{ "found": false }`.
func remoteLyricsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeAPIError(w, "GET only", http.StatusMethodNotAllowed)
		return
	}
	id := strings.TrimSpace(r.URL.Query().Get("id"))
	if id == "" {
		writeAPIError(w, "missing id", http.StatusBadRequest)
		return
	}
	song, ok := remoteLibrarySongByID(id)
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
		out := map[string]interface{}{
			"found":   true,
			"type":    typ,
			"content": content,
		}
		if translationContent := strings.TrimSpace(res["translationContent"]); translationContent != "" {
			out["translationContent"] = res["translationContent"]
			out["translationFormat"] = res["translationFormat"]
		}
		writeJSON(w, out)
		return
	}
	writeJSON(w, map[string]interface{}{"found": false})
}

// remotePlaylistsHandler serves `GET /v1/remote/playlists` as a JSON array of
// `{ "name": string, "songIds": [...], "pathsNotInLibrary"?: [...] }`.
func remotePlaylistsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeAPIError(w, "GET only", http.StatusMethodNotAllowed)
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
			if id, ok := remotePlaylistPathToSongID(pathToID, p); ok {
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

// remoteSituationPlaylistsHandler serves `GET /v1/remote/situation-playlists`
// as a JSON array of `{ "name": string, "songIds": [...] }`, in the fixed
// order (recently added → most played → random pick), omitting any entry
// whose song list is empty. It shares the picking logic with the
// Wails-facing (*App).GetSituationPlaylists via generateSituationPlaylists.
func remoteSituationPlaylistsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeAPIError(w, "GET only", http.StatusMethodNotAllowed)
		return
	}
	songs, err := store.Instance.LoadSlice("library")
	if err != nil || len(songs) == 0 {
		writeJSON(w, []interface{}{})
		return
	}
	counts, _ := store.Instance.LoadMap("playcounts")

	out := make([]map[string]interface{}, 0, 3)
	for _, bucket := range generateSituationPlaylists(songs, counts) {
		ids := make([]string, 0, len(bucket.songs))
		for _, s := range bucket.songs {
			song, ok := s.(map[string]interface{})
			if !ok {
				continue
			}
			if id, _ := song["id"].(string); id != "" {
				ids = append(ids, id)
			}
		}
		if len(ids) == 0 {
			continue
		}
		out = append(out, map[string]interface{}{
			"name":    bucket.name,
			"songIds": ids,
		})
	}
	writeJSON(w, out)
}

func remotePlaylistPathToSongID(pathToID map[string]string, playlistPath string) (string, bool) {
	if pathToID == nil || playlistPath == "" {
		return "", false
	}
	candidates := pathutil.SlashCandidateForms(playlistPath)
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

// remoteLibrarySongByID returns the raw library map for a song id (or path-shaped legacy id).
func remoteLibrarySongByID(id string) (map[string]interface{}, bool) {
	library, err := store.Instance.LoadSlice("library")
	if err != nil || len(library) == 0 {
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
