package server

import (
	"fmt"
	"math/rand"
	"sort"
	"strings"
	"time"
)

const situationPlaylistMaxItems = 20
const situationRediscoverStaleAfter = 30 * 24 * time.Hour

// situationPlaylistBucket is one generated "For You" playlist: a stable key
// for the Wails-facing map, the display name and short Japanese description,
// the picked songs, and up to 4 distinct collage artworks.
type situationPlaylistBucket struct {
	key         string
	name        string
	description string
	songs       []interface{}
	artworks    []interface{}
}

// generateSituationPlaylists picks the "For You" buckets in a fixed display
// order, omitting any bucket whose song list came back empty. Both the
// Wails-facing (*App).GetSituationPlaylists and the LAN API's
// remoteSituationPlaylistsHandler share this so the picking logic lives in
// one place.
//
// seed is derived from `now` truncated to the day (dailySeed) so that
// weighted/random picks (artist_spotlight, genre_mix/decade_mix) stay stable
// across repeated calls within the same day and only reshuffle once a day.
func generateSituationPlaylists(songs []interface{}, counts map[string]interface{}, now time.Time) []situationPlaylistBucket {
	if len(songs) == 0 {
		return nil
	}
	seed := dailySeed(now)
	lastPlayed := lastPlayedByPath(counts)

	candidates := make([]situationPlaylistBucket, 0, 8)

	candidates = append(candidates, situationPlaylistBucket{
		key:         "recently_added",
		name:        "最近追加した曲",
		description: "最近ライブラリに追加した曲",
		songs:       pickRecentlyAdded(songs, situationPlaylistMaxItems),
	})

	if mostPlayed := pickMostPlayed(songs, counts, situationPlaylistMaxItems); len(mostPlayed) > 0 {
		candidates = append(candidates, situationPlaylistBucket{
			key:         "most_played",
			name:        "よく聴く曲",
			description: "再生回数が多い曲",
			songs:       mostPlayed,
		})
	} else if recentlyPlayed := pickRecentlyPlayed(songs, lastPlayed, situationPlaylistMaxItems); len(recentlyPlayed) > 0 {
		candidates = append(candidates, situationPlaylistBucket{
			key:         "most_played",
			name:        "最近再生した曲",
			description: "最近再生した曲",
			songs:       recentlyPlayed,
		})
	}

	candidates = append(candidates, situationPlaylistBucket{
		key:         "random_pick",
		name:        "ランダムピック",
		description: "ライブラリからランダムに選んだ曲",
		songs:       pickRandomPick(songs, situationPlaylistMaxItems),
	})

	if rediscover := pickRediscover(songs, counts, lastPlayed, now, situationPlaylistMaxItems); len(rediscover) > 0 {
		candidates = append(candidates, situationPlaylistBucket{
			key:         "rediscover",
			name:        "聴き返したい曲",
			description: "しばらく再生していない、よく聴いていた曲",
			songs:       rediscover,
		})
	}

	if artist, spotlight := pickArtistSpotlight(songs, counts, seed, situationPlaylistMaxItems); len(spotlight) > 0 {
		candidates = append(candidates, situationPlaylistBucket{
			key:         "artist_spotlight",
			name:        fmt.Sprintf("%s の特集", artist),
			description: "よく聴いているアーティストの特集",
			songs:       spotlight,
		})
	}

	if deepCuts := pickAlbumDeepCut(songs, counts, situationPlaylistMaxItems); len(deepCuts) > 0 {
		candidates = append(candidates, situationPlaylistBucket{
			key:         "album_deep_cut",
			name:        "アルバムの隠れた名曲",
			description: "よく聴くアルバムの中で、まだあまり再生していない曲",
			songs:       deepCuts,
		})
	}

	if key, name, description, mix := pickGenreOrDecadeMix(songs, seed, situationPlaylistMaxItems); len(mix) > 0 {
		candidates = append(candidates, situationPlaylistBucket{
			key:         key,
			name:        name,
			description: description,
			songs:       mix,
		})
	}

	out := make([]situationPlaylistBucket, 0, len(candidates))
	for _, c := range candidates {
		if len(c.songs) == 0 {
			continue
		}
		c.artworks = collageArtworks(c.songs)
		out = append(out, c)
	}
	return out
}

// dailySeed derives a seed that is stable for any timestamp within the same
// UTC calendar day and changes once a day, so seeded picks (artist_spotlight,
// genre_mix/decade_mix) don't reshuffle every time the "For You" tab is
// reopened but do refresh daily.
func dailySeed(now time.Time) int64 {
	return now.UTC().Truncate(24 * time.Hour).Unix()
}

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

// playCountFromEntry reads the "count" field out of one playcounts[path]
// entry (see normalisePlayCountEntry in app_sync_auto.go), returning 0 for
// anything that isn't the expected shape.
func playCountFromEntry(raw interface{}) int {
	entry, ok := raw.(map[string]interface{})
	if !ok {
		return 0
	}
	c, ok := entry["count"].(float64)
	if !ok {
		return 0
	}
	return int(c)
}

// lastPlayedByPath derives a last-played timestamp per library path from the
// existing playcounts store, rather than adding a new store: every counted
// play appends an RFC3339 timestamp to playcounts[path]["history"] (see
// recalculateAllSyncPlayCounts / recordLocalSyncPlayEvent in
// app_sync_auto.go, which runs on every IncrementPlayCount call). A path
// with no parseable history entries is omitted.
func lastPlayedByPath(counts map[string]interface{}) map[string]time.Time {
	out := make(map[string]time.Time)
	for path, raw := range counts {
		entry, ok := raw.(map[string]interface{})
		if !ok {
			continue
		}
		history, ok := entry["history"].([]interface{})
		if !ok {
			continue
		}
		var latest time.Time
		for _, h := range history {
			s, ok := h.(string)
			if !ok {
				continue
			}
			t, err := time.Parse(time.RFC3339, s)
			if err != nil {
				continue
			}
			if t.After(latest) {
				latest = t
			}
		}
		if !latest.IsZero() {
			out[path] = latest
		}
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
		c := playCountFromEntry(raw)
		if c <= 0 {
			continue
		}
		scored = append(scored, songWithCount{song: s, count: c})
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

// pickRecentlyPlayed is the "most_played" bucket's fallback for libraries
// that have no accumulated play counts yet but do have at least one recorded
// play: it sorts by lastPlayed descending (most recent first) instead of by
// count.
func pickRecentlyPlayed(songs []interface{}, lastPlayed map[string]time.Time, limit int) []interface{} {
	if len(songs) == 0 || len(lastPlayed) == 0 || limit <= 0 {
		return []interface{}{}
	}
	type songWithTime struct {
		song interface{}
		t    time.Time
	}
	scored := make([]songWithTime, 0, len(songs))
	for _, s := range songs {
		song, ok := s.(map[string]interface{})
		if !ok {
			continue
		}
		path, _ := song["path"].(string)
		t, ok := lastPlayed[path]
		if !ok {
			continue
		}
		scored = append(scored, songWithTime{song: s, t: t})
	}
	sort.Slice(scored, func(i, j int) bool { return scored[i].t.After(scored[j].t) })
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
// Returns an empty slice for libraries smaller than 2 songs, where a
// "random pick" doesn't add anything over the full library.
func pickRandomPick(songs []interface{}, limit int) []interface{} {
	if len(songs) < 2 || limit <= 0 {
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

// pickRediscover surfaces songs that were played before (count > 0) but not
// recently: either their last play predates the 30-day staleness window, or
// there's no recorded lastPlayed at all (legacy playcounts data migrated
// before history tracking existed, which we can't disprove is stale).
// Results are ordered oldest-last-played first, so the most "forgotten"
// songs surface first.
func pickRediscover(songs []interface{}, counts map[string]interface{}, lastPlayed map[string]time.Time, now time.Time, limit int) []interface{} {
	if len(songs) == 0 || len(counts) == 0 || limit <= 0 {
		return []interface{}{}
	}
	cutoff := now.Add(-situationRediscoverStaleAfter)
	type songWithTime struct {
		song interface{}
		t    time.Time
	}
	scored := make([]songWithTime, 0, len(songs))
	for _, s := range songs {
		song, ok := s.(map[string]interface{})
		if !ok {
			continue
		}
		path, _ := song["path"].(string)
		if playCountFromEntry(counts[path]) <= 0 {
			continue
		}
		t, hasLast := lastPlayed[path]
		if hasLast && t.After(cutoff) {
			continue
		}
		scored = append(scored, songWithTime{song: s, t: t})
	}
	sort.Slice(scored, func(i, j int) bool { return scored[i].t.Before(scored[j].t) })
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

// pickArtistSpotlight picks one artist by playcount-weighted random choice
// (roulette-wheel selection, seeded so it's stable within a day - see
// dailySeed) and returns that artist's songs. Artists with zero total
// playcount are excluded from the weighting, and songs with no artist
// metadata are ignored. Returns ("", nil) when no artist has any plays.
func pickArtistSpotlight(songs []interface{}, counts map[string]interface{}, seed int64, limit int) (string, []interface{}) {
	if len(songs) == 0 || len(counts) == 0 || limit <= 0 {
		return "", nil
	}
	weightByArtist := map[string]int{}
	songsByArtist := map[string][]interface{}{}
	for _, s := range songs {
		song, ok := s.(map[string]interface{})
		if !ok {
			continue
		}
		artist := strings.TrimSpace(fmt.Sprint(song["artist"]))
		if artist == "" || artist == "<nil>" {
			continue
		}
		path, _ := song["path"].(string)
		weightByArtist[artist] += playCountFromEntry(counts[path])
		songsByArtist[artist] = append(songsByArtist[artist], s)
	}

	artists := make([]string, 0, len(weightByArtist))
	total := 0
	for artist, w := range weightByArtist {
		if w <= 0 {
			continue
		}
		artists = append(artists, artist)
		total += w
	}
	if total <= 0 {
		return "", nil
	}
	// Sort for a deterministic roulette-wheel order; map iteration order is
	// randomised in Go and would otherwise make the seeded pick unstable.
	sort.Strings(artists)

	r := rand.New(rand.NewSource(seed))
	pick := r.Intn(total)
	chosen := artists[0]
	acc := 0
	for _, artist := range artists {
		acc += weightByArtist[artist]
		if pick < acc {
			chosen = artist
			break
		}
	}

	pool := songsByArtist[chosen]
	n := limit
	if len(pool) < n {
		n = len(pool)
	}
	return chosen, pool[:n]
}

// pickAlbumDeepCut surfaces the least-played songs from the most-played
// albums: albums are ranked by their total playcount, and within each album
// (visited most-played album first) songs are emitted least-played first.
// Albums with zero total playcount are excluded entirely.
func pickAlbumDeepCut(songs []interface{}, counts map[string]interface{}, limit int) []interface{} {
	if len(songs) == 0 || len(counts) == 0 || limit <= 0 {
		return []interface{}{}
	}
	type albumSong struct {
		song  interface{}
		count int
	}
	albumWeight := map[string]int{}
	albumSongs := map[string][]albumSong{}
	for _, s := range songs {
		song, ok := s.(map[string]interface{})
		if !ok {
			continue
		}
		album := strings.TrimSpace(fmt.Sprint(song["album"]))
		if album == "" || album == "<nil>" {
			continue
		}
		path, _ := song["path"].(string)
		count := playCountFromEntry(counts[path])
		albumWeight[album] += count
		albumSongs[album] = append(albumSongs[album], albumSong{song: s, count: count})
	}

	albums := make([]string, 0, len(albumWeight))
	for album, w := range albumWeight {
		if w > 0 {
			albums = append(albums, album)
		}
	}
	if len(albums) == 0 {
		return []interface{}{}
	}
	sort.Slice(albums, func(i, j int) bool {
		if albumWeight[albums[i]] != albumWeight[albums[j]] {
			return albumWeight[albums[i]] > albumWeight[albums[j]]
		}
		return albums[i] < albums[j]
	})

	out := make([]interface{}, 0, limit)
	for _, album := range albums {
		pool := albumSongs[album]
		sort.Slice(pool, func(i, j int) bool { return pool[i].count < pool[j].count })
		for _, as := range pool {
			out = append(out, as.song)
			if len(out) >= limit {
				return out
			}
		}
	}
	return out
}

// pickGenreOrDecadeMix builds one metadata-driven mix bucket: it prefers
// genre_mix when any song has genre metadata, picking one genre
// deterministically via seed; otherwise it falls back to decade_mix using
// the "year" field. Returns ("", "", "", nil) when neither genre nor year
// metadata is present in the library.
func pickGenreOrDecadeMix(songs []interface{}, seed int64, limit int) (string, string, string, []interface{}) {
	if len(songs) == 0 || limit <= 0 {
		return "", "", "", nil
	}

	genreSongs := map[string][]interface{}{}
	for _, s := range songs {
		song, ok := s.(map[string]interface{})
		if !ok {
			continue
		}
		genre, _ := song["genre"].(string)
		genre = strings.TrimSpace(genre)
		if genre == "" {
			continue
		}
		genreSongs[genre] = append(genreSongs[genre], s)
	}
	if len(genreSongs) > 0 {
		genres := make([]string, 0, len(genreSongs))
		for g := range genreSongs {
			genres = append(genres, g)
		}
		sort.Strings(genres)
		chosen := genres[seed%int64(len(genres))]
		pool := genreSongs[chosen]
		n := limit
		if len(pool) < n {
			n = len(pool)
		}
		return "genre_mix", fmt.Sprintf("%s ミックス", chosen),
			fmt.Sprintf("「%s」ジャンルの曲を集めたミックス", chosen), pool[:n]
	}

	decadeSongs := map[int][]interface{}{}
	for _, s := range songs {
		song, ok := s.(map[string]interface{})
		if !ok {
			continue
		}
		year := yearFromSong(song)
		if year <= 0 {
			continue
		}
		decade := (year / 10) * 10
		decadeSongs[decade] = append(decadeSongs[decade], s)
	}
	if len(decadeSongs) == 0 {
		return "", "", "", nil
	}
	decades := make([]int, 0, len(decadeSongs))
	for d := range decadeSongs {
		decades = append(decades, d)
	}
	sort.Ints(decades)
	chosen := decades[seed%int64(len(decades))]
	pool := decadeSongs[chosen]
	n := limit
	if len(pool) < n {
		n = len(pool)
	}
	return "decade_mix", fmt.Sprintf("%d年代ミックス", chosen),
		fmt.Sprintf("%d年代にリリースされた曲を集めたミックス", chosen), pool[:n]
}

func yearFromSong(song map[string]interface{}) int {
	switch v := song["year"].(type) {
	case float64:
		return int(v)
	case int:
		return v
	}
	return 0
}
