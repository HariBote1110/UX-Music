package server

import "strings"

// artworkPathFromSong extracts a usable artwork path/URL from a song map.
//
// Locally scanned songs store artwork as a nested map produced by
// internal/scanner/artwork.go (extractAndSaveArtwork /
// PersistArtworkBytes): {"full": "<hash>.webp", "thumbnail": "<hash>_thumb.webp"}.
// Depending on whether the value has been through a JSON round-trip via
// store.Instance, that map surfaces as either map[string]interface{} or
// map[string]string, so both are handled. YouTube-sourced songs
// (app_youtube.go) store a plain string thumbnail URL instead.
//
// Thumbnail is preferred over the full-size image because callers use this
// for small collage tiles (see collageArtworks and app_queue.go's Now
// Playing metadata, which instead wants the full image and keeps its own
// inline type assertion).
func artworkPathFromSong(song map[string]interface{}) string {
	if song == nil {
		return ""
	}
	switch art := song["artwork"].(type) {
	case string:
		return strings.TrimSpace(art)
	case map[string]interface{}:
		if thumb, ok := art["thumbnail"].(string); ok && strings.TrimSpace(thumb) != "" {
			return thumb
		}
		if full, ok := art["full"].(string); ok && strings.TrimSpace(full) != "" {
			return full
		}
	case map[string]string:
		if thumb, ok := art["thumbnail"]; ok && strings.TrimSpace(thumb) != "" {
			return thumb
		}
		if full, ok := art["full"]; ok && strings.TrimSpace(full) != "" {
			return full
		}
	}
	return ""
}

// collageArtworks picks up to 4 distinct artworks from a playlist's songs,
// preferring one cover per distinct album so a collage of a mixed playlist
// doesn't just repeat the same image. Falls back to deduping by artwork path
// alone when a song has no album metadata (e.g. some YouTube entries).
//
// It never pads the result with repeats: a playlist with fewer than 4
// distinct covers returns fewer than 4 entries, and the frontend shows a
// single image in that case.
func collageArtworks(songs []interface{}) []string {
	artworks := make([]string, 0, 4)
	seenAlbums := make(map[string]bool)
	seenArtworks := make(map[string]bool)
	for _, s := range songs {
		song, ok := s.(map[string]interface{})
		if !ok {
			continue
		}
		artwork := artworkPathFromSong(song)
		if artwork == "" || seenArtworks[artwork] {
			continue
		}
		if album, ok := song["album"].(string); ok {
			if albumKey := strings.TrimSpace(album); albumKey != "" {
				if seenAlbums[albumKey] {
					continue
				}
				seenAlbums[albumKey] = true
			}
		}
		artworks = append(artworks, artwork)
		seenArtworks[artwork] = true
		if len(artworks) >= 4 {
			break
		}
	}
	return artworks
}
