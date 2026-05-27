package server

import "sort"

const situationPlaylistMaxItems = 20

// pickRecentlyAdded returns the last `limit` entries of `songs` in reverse
// insertion order (newest first). Library is assumed to be append-only, so
// the tail represents the most recent additions.
func pickRecentlyAdded(songs []interface{}, limit int) []interface{} {
	if len(songs) == 0 || limit <= 0 {
		return []interface{}{}
	}
	n := limit
	if len(songs) < n {
		n = len(songs)
	}
	out := make([]interface{}, 0, n)
	for i := len(songs) - 1; i >= len(songs)-n; i-- {
		out = append(out, songs[i])
	}
	return out
}

// pickMostPlayed joins songs against the playcounts map by `path`, keeps only
// entries with count > 0, sorts by count descending, and returns up to `limit`.
func pickMostPlayed(songs []interface{}, counts map[string]interface{}, limit int) []interface{} {
	if len(songs) == 0 || len(counts) == 0 || limit <= 0 {
		return []interface{}{}
	}
	type songWithCount struct {
		song  interface{}
		count int
	}
	scored := make([]songWithCount, 0, len(songs))
	for _, s := range songs {
		song, ok := s.(map[string]interface{})
		if !ok {
			continue
		}
		path, ok := song["path"].(string)
		if !ok {
			continue
		}
		raw, exists := counts[path]
		if !exists {
			continue
		}
		entry, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		c, ok := entry["count"].(float64)
		if !ok || c <= 0 {
			continue
		}
		scored = append(scored, songWithCount{song: s, count: int(c)})
	}
	sort.Slice(scored, func(i, j int) bool { return scored[i].count > scored[j].count })

	n := limit
	if len(scored) < n {
		n = len(scored)
	}
	out := make([]interface{}, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, scored[i].song)
	}
	return out
}

// pickRandomPick samples up to `limit` songs by striding across the library.
// Returns an empty slice when the library is too small (< 5) so callers can
// hide the section entirely.
func pickRandomPick(songs []interface{}, limit int) []interface{} {
	if len(songs) < 5 || limit <= 0 {
		return []interface{}{}
	}
	cap := limit
	if len(songs) < cap {
		cap = len(songs)
	}
	step := len(songs) / cap
	if step < 1 {
		step = 1
	}
	out := make([]interface{}, 0, cap)
	for i := 0; i < len(songs) && len(out) < cap; i += step {
		out = append(out, songs[i])
	}
	return out
}
