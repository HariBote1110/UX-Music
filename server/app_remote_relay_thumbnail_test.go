package server

import (
	"sync"
	"testing"
)

func TestResolveBestYouTubeThumbnail_PicksMaxresWhenAvailable(t *testing.T) {
	var probed []string
	probe := func(url string) bool {
		probed = append(probed, url)
		return url == youtubeThumbnailCandidateURL("abc123", "maxresdefault")
	}

	got := resolveBestYouTubeThumbnail("abc123", probe)
	want := youtubeThumbnailCandidateURL("abc123", "maxresdefault")
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
	if len(probed) != 1 {
		t.Fatalf("expected to stop probing after the first success, probed %v", probed)
	}
}

func TestResolveBestYouTubeThumbnail_FallsBackToSDWhenMaxresMissing(t *testing.T) {
	probe := func(url string) bool {
		return url == youtubeThumbnailCandidateURL("abc123", "sddefault")
	}

	got := resolveBestYouTubeThumbnail("abc123", probe)
	want := youtubeThumbnailCandidateURL("abc123", "sddefault")
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestResolveBestYouTubeThumbnail_FallsBackToHQWhenNothingElseAvailable(t *testing.T) {
	probe := func(url string) bool { return false }

	got := resolveBestYouTubeThumbnail("abc123", probe)
	want := youtubeThumbnailCandidateURL("abc123", "hqdefault")
	if got != want {
		t.Fatalf("got %q, want %q (hqdefault must be the unconditional final fallback)", got, want)
	}
}

func TestResolveBestYouTubeThumbnail_ProbesInHighToLowOrder(t *testing.T) {
	var order []string
	probe := func(url string) bool {
		order = append(order, url)
		return false
	}
	resolveBestYouTubeThumbnail("abc123", probe)

	want := []string{
		youtubeThumbnailCandidateURL("abc123", "maxresdefault"),
		youtubeThumbnailCandidateURL("abc123", "sddefault"),
		youtubeThumbnailCandidateURL("abc123", "hqdefault"),
	}
	if len(order) != len(want) {
		t.Fatalf("probed %v, want %v", order, want)
	}
	for i := range want {
		if order[i] != want[i] {
			t.Fatalf("probe order[%d] = %q, want %q", i, order[i], want[i])
		}
	}
}

func TestResolveRelayThumbnailURL_NonYouTubeURLPassesThrough(t *testing.T) {
	relayThumbnailCache = sync.Map{}
	original := probeYouTubeThumbnailAvailable
	probeYouTubeThumbnailAvailable = func(url string) bool {
		t.Fatalf("must not probe a non-YouTube-thumbnail URL, got %q", url)
		return false
	}
	t.Cleanup(func() { probeYouTubeThumbnailAvailable = original })

	got := resolveRelayThumbnailURL("https://example.com/some/other/thumbnail.jpg")
	if got != "https://example.com/some/other/thumbnail.jpg" {
		t.Fatalf("expected pass-through, got %q", got)
	}
}

func TestResolveRelayThumbnailURL_EmptyURLPassesThrough(t *testing.T) {
	relayThumbnailCache = sync.Map{}
	got := resolveRelayThumbnailURL("")
	if got != "" {
		t.Fatalf("expected pass-through for empty URL, got %q", got)
	}
}

func TestResolveRelayThumbnailURL_UpgradesRecognisedYouTubeThumbnail(t *testing.T) {
	relayThumbnailCache = sync.Map{}
	original := probeYouTubeThumbnailAvailable
	probeYouTubeThumbnailAvailable = func(url string) bool {
		return url == youtubeThumbnailCandidateURL("xyz789", "sddefault")
	}
	t.Cleanup(func() { probeYouTubeThumbnailAvailable = original })

	got := resolveRelayThumbnailURL(youtubeThumbnailCandidateURL("xyz789", "hqdefault"))
	want := youtubeThumbnailCandidateURL("xyz789", "sddefault")
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestResolveRelayThumbnailURL_CachesPerVideoID(t *testing.T) {
	relayThumbnailCache = sync.Map{}
	callCount := 0
	original := probeYouTubeThumbnailAvailable
	probeYouTubeThumbnailAvailable = func(url string) bool {
		callCount++
		return url == youtubeThumbnailCandidateURL("cached-1", "maxresdefault")
	}
	t.Cleanup(func() { probeYouTubeThumbnailAvailable = original })

	first := resolveRelayThumbnailURL(youtubeThumbnailCandidateURL("cached-1", "hqdefault"))
	second := resolveRelayThumbnailURL(youtubeThumbnailCandidateURL("cached-1", "hqdefault"))

	if first != second {
		t.Fatalf("expected cached result to be stable, got %q then %q", first, second)
	}
	if callCount != 1 {
		t.Fatalf("expected probing only once (cached thereafter), probed %d times", callCount)
	}
}
