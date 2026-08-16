package server

import (
	"strconv"
	"strings"
)

// dedupRemoteSongs collapses duplicate library entries before they reach remote
// clients (TV, mobile). The library store can genuinely hold more than one
// entry for the same physical track: a CD-rip staging copy alongside the
// organised copy once a file has been filed into its album folder, or two
// rips of the same disc registered with slightly different filenames (and
// therefore a discNumber of 0 on one, 1 on the other). Cleaning the store
// itself is out of scope here — this keeps the fix non-destructive and
// leaves the desktop app (which reads the store directly) untouched, while
// giving remote clients a single canonical entry per track.
func dedupRemoteSongs(songs []map[string]interface{}) []map[string]interface{} {
	if len(songs) == 0 {
		return songs
	}

	type slot struct {
		index int
		song  map[string]interface{}
	}
	best := make(map[string]slot)
	order := make([]string, 0, len(songs))
	result := make([]map[string]interface{}, 0, len(songs))
	passthrough := make(map[int]bool)

	for i, m := range songs {
		if !songHasLocalAudio(m) {
			passthrough[i] = true
			continue
		}
		key := remoteDedupKey(m)
		existing, seen := best[key]
		if !seen {
			best[key] = slot{index: i, song: m}
			order = append(order, key)
			continue
		}
		if remoteDedupPreferred(m, existing.song) {
			best[key] = slot{index: i, song: m}
		}
	}

	kept := make(map[int]bool, len(best))
	for _, key := range order {
		kept[best[key].index] = true
	}

	for i, m := range songs {
		if passthrough[i] || kept[i] {
			result = append(result, m)
		}
	}
	return result
}

// remoteDedupKey identifies "the same track" for dedup purposes: title,
// album, artist, track number and normalised disc number (0 treated as 1,
// since disc 0 typically just means "disc tag missing" rather than a real
// second disc).
func remoteDedupKey(m map[string]interface{}) string {
	title := strings.ToLower(strings.TrimSpace(remoteStringField(m, "title")))
	album := strings.ToLower(strings.TrimSpace(remoteStringField(m, "album")))
	artist := strings.ToLower(strings.TrimSpace(remoteStringField(m, "artist")))
	disc := remoteIntField(m, "discNumber")
	if disc <= 0 {
		disc = 1
	}
	track := remoteIntField(m, "trackNumber")
	return title + "\x00" + album + "\x00" + artist + "\x00" +
		strconv.Itoa(track) + "\x00" + strconv.Itoa(disc)
}

// remoteDedupPreferred reports whether candidate should replace incumbent as
// the canonical entry for a dedup key: a UUID-format id (from a proper scan)
// beats a legacy path-string id, then a larger fileSize wins (more likely
// the complete/organised copy), otherwise the earlier entry is kept.
func remoteDedupPreferred(candidate, incumbent map[string]interface{}) bool {
	candidateUUID := remoteIDLooksLikeUUID(remoteStringField(candidate, "id"))
	incumbentUUID := remoteIDLooksLikeUUID(remoteStringField(incumbent, "id"))
	if candidateUUID != incumbentUUID {
		return candidateUUID
	}
	candidateSize := remoteFloatField(candidate, "fileSize")
	incumbentSize := remoteFloatField(incumbent, "fileSize")
	if candidateSize != incumbentSize {
		return candidateSize > incumbentSize
	}
	return false
}

func remoteIDLooksLikeUUID(id string) bool {
	return len(id) == 36 && strings.Count(id, "-") == 4
}

func remoteFloatField(m map[string]interface{}, key string) float64 {
	v, ok := m[key]
	if !ok || v == nil {
		return 0
	}
	switch x := v.(type) {
	case float64:
		return x
	case int:
		return float64(x)
	default:
		return 0
	}
}
