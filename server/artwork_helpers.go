package server

import "strings"

// artworkPathFromSong extracts a usable artwork value from a song map,
// preserving its shape end-to-end.
//
// Locally scanned songs store artwork as a nested map produced by
// internal/scanner/artwork.go (extractAndSaveArtwork /
// PersistArtworkBytes): {"full": "<hash>.webp", "thumbnail": "<hash>_thumb.webp"}.
// Depending on whether the value has been through a JSON round-trip via
// store.Instance, that map surfaces as either map[string]interface{} or
// map[string]string, so both are handled and normalised to
// map[string]interface{}. YouTube-sourced songs (app_youtube.go) store a
// plain string thumbnail URL instead, which is returned unchanged.
//
// The caller (frontend's resolveArtworkPath, src/renderer/js/ui/utils.ts)
// relies on this shape to pick the right URL: a map with full/thumbnail
// resolves to /safe-artwork/thumbnails/<name> or /safe-artwork/<name>
// depending on the requested size, while a bare string is treated as either
// an external URL or a legacy full-size file name. Collapsing the map down
// to a single preferred string here (as a previous version of this
// function did) broke that distinction and made collage thumbnails 404.
func artworkPathFromSong(song map[string]interface{}) interface{} {
	if song == nil {
		return nil
	}
	switch art := song["artwork"].(type) {
	case string:
		if s := strings.TrimSpace(art); s != "" {
			return s
		}
	case map[string]interface{}:
		full, _ := art["full"].(string)
		thumbnail, _ := art["thumbnail"].(string)
		if strings.TrimSpace(full) != "" || strings.TrimSpace(thumbnail) != "" {
			return map[string]interface{}{"full": full, "thumbnail": thumbnail}
		}
	case map[string]string:
		full := art["full"]
		thumbnail := art["thumbnail"]
		if strings.TrimSpace(full) != "" || strings.TrimSpace(thumbnail) != "" {
			return map[string]interface{}{"full": full, "thumbnail": thumbnail}
		}
	}
	return nil
}

// artworkDedupKey returns the string used to detect duplicate covers in
// collageArtworks: the thumbnail name when present (falling back to full),
// or the artwork string itself for YouTube URLs/legacy strings.
func artworkDedupKey(artwork interface{}) string {
	switch a := artwork.(type) {
	case string:
		return a
	case map[string]interface{}:
		if thumb, ok := a["thumbnail"].(string); ok && strings.TrimSpace(thumb) != "" {
			return thumb
		}
		if full, ok := a["full"].(string); ok {
			return full
		}
	}
	return ""
}

// collageArtworks picks up to 4 distinct artworks from a playlist's songs,
// preferring one cover per distinct album so a collage of a mixed playlist
// doesn't just repeat the same image. Falls back to deduping by artwork
// dedup key alone when a song has no album metadata (e.g. some YouTube
// entries).
//
// Each returned entry preserves the shape artworkPathFromSong produced
// (either a {"full","thumbnail"} object or a plain string) so the frontend
// can resolve the correct thumbnail/full URL for each size it needs.
//
// It never pads the result with repeats: a playlist with fewer than 4
// distinct covers returns fewer than 4 entries, and the frontend shows a
// single image in that case.
func collageArtworks(songs []interface{}) []interface{} {
	artworks := make([]interface{}, 0, 4)
	seenAlbums := make(map[string]bool)
	seenArtworks := make(map[string]bool)
	for _, s := range songs {
		song, ok := s.(map[string]interface{})
		if !ok {
			continue
		}
		artwork := artworkPathFromSong(song)
		dedupKey := artworkDedupKey(artwork)
		if dedupKey == "" || seenArtworks[dedupKey] {
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
		seenArtworks[dedupKey] = true
		if len(artworks) >= 4 {
			break
		}
	}
	return artworks
}
