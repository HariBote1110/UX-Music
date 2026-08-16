package server

import (
	"net/http"
	"regexp"
	"sync"
	"time"
)

// youtubeThumbnailVideoIDPattern matches https://i.ytimg.com/vi/{videoId}/{name}.jpg
// URLs — the shape resolveRelayThumbnailCandidate (renderer,
// features/youtube-thumbnail.ts) builds when it has a YouTube video ID
// available — so NotifyYouTubePlaybackState can recover the video ID and
// probe for the actual highest-resolution thumbnail that exists for it.
var youtubeThumbnailVideoIDPattern = regexp.MustCompile(`^https://i\.ytimg\.com/vi/([\w-]+)/[\w.]+$`)

// youtubeThumbnailQualities is the highest→lowest fallback chain per the
// "サムネをできる限り綺麗に転送する" policy: maxresdefault does not exist for
// every video (older or short uploads often lack it — YouTube serves a 404
// rather than a placeholder for it specifically), so the chain is probed
// top-down and the first one actually served is used.
var youtubeThumbnailQualities = []string{"maxresdefault", "sddefault", "hqdefault"}

func youtubeThumbnailCandidateURL(videoID, quality string) string {
	return "https://i.ytimg.com/vi/" + videoID + "/" + quality + ".jpg"
}

// resolveBestYouTubeThumbnail walks youtubeThumbnailQualities from highest
// to lowest and returns the first candidate probe reports available. If
// every probe fails, it returns the last (lowest-quality, hqdefault)
// candidate anyway — YouTube serves hqdefault for essentially every video,
// so it is the safest unconditional fallback.
//
// Pure aside from the injected probe function, so the fallback-chain
// selection logic is unit-testable without real network access (see
// app_remote_relay_thumbnail_test.go).
func resolveBestYouTubeThumbnail(videoID string, probe func(url string) bool) string {
	var last string
	for _, quality := range youtubeThumbnailQualities {
		candidate := youtubeThumbnailCandidateURL(videoID, quality)
		last = candidate
		if probe(candidate) {
			return candidate
		}
	}
	return last
}

// relayThumbnailCache remembers the resolved best-quality thumbnail per
// video ID, keyed by video ID, so repeated NotifyYouTubePlaybackState calls
// for the same song (replay, reattach after a tap failure, etc.) don't
// re-probe the network every time — probing happens at most once per video
// ID, off the audio path.
var relayThumbnailCache sync.Map // videoID string -> resolved URL string

// probeYouTubeThumbnailAvailable is the real HEAD-probe used in production;
// swapped out in tests to avoid real network access.
var probeYouTubeThumbnailAvailable = func(url string) bool {
	client := http.Client{Timeout: 3 * time.Second}
	resp, err := client.Head(url)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

// resolveRelayThumbnailURL upgrades thumbnailURL to the highest-resolution
// YouTube thumbnail actually available for the video, when thumbnailURL is
// recognisably a YouTube thumbnail URL (youtubeThumbnailVideoIDPattern).
// Anything else — a non-YouTube URL, or no video ID recoverable — passes
// through unchanged, so this is safe to call unconditionally from
// NotifyYouTubePlaybackState regardless of what the renderer supplied.
func resolveRelayThumbnailURL(thumbnailURL string) string {
	match := youtubeThumbnailVideoIDPattern.FindStringSubmatch(thumbnailURL)
	if match == nil {
		return thumbnailURL
	}
	videoID := match[1]

	if cached, ok := relayThumbnailCache.Load(videoID); ok {
		return cached.(string)
	}

	best := resolveBestYouTubeThumbnail(videoID, probeYouTubeThumbnailAvailable)
	relayThumbnailCache.Store(videoID, best)
	return best
}
