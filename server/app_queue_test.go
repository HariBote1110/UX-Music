package server

import (
	"context"
	"fmt"
	"testing"
	"time"

	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/pkg/playqueue"
)

// newQueueTestApp is the app_queue.go analogue of newRemoteCommandTestApp:
// a headless App (no audioPlayer) with an emit spy.
func newQueueTestApp(t *testing.T) (*App, *[]struct {
	name string
	data interface{}
}) {
	t.Helper()
	emitted := &[]struct {
		name string
		data interface{}
	}{}
	app := &App{
		ctx: context.Background(),
		playCountsEmitter: func(_ context.Context, name string, data interface{}) {
			*emitted = append(*emitted, struct {
				name string
				data interface{}
			}{name: name, data: data})
		},
	}
	return app, emitted
}

func lastEmit(emitted *[]struct {
	name string
	data interface{}
}, name string) (interface{}, bool) {
	for i := len(*emitted) - 1; i >= 0; i-- {
		if (*emitted)[i].name == name {
			return (*emitted)[i].data, true
		}
	}
	return nil, false
}

func hasEmit(emitted *[]struct {
	name string
	data interface{}
}, name string) bool {
	_, ok := lastEmit(emitted, name)
	return ok
}

func TestSongMapToQueueItem(t *testing.T) {
	local := songMapToQueueItem(map[string]interface{}{
		"id": "s1", "path": "/music/s1.mp3", "title": "T", "artist": "A", "album": "Al",
	})
	if local.Type != playqueue.ItemTypeLocal {
		t.Fatalf("Type = %v, want local (defaulted from path presence)", local.Type)
	}
	if local.ID != "s1" || local.Path != "/music/s1.mp3" || local.Title != "T" {
		t.Fatalf("unexpected item: %+v", local)
	}

	yt := songMapToQueueItem(map[string]interface{}{
		"id": "y1", "path": "https://youtu.be/xyz", "type": "youtube", "title": "YT",
	})
	if yt.Type != playqueue.ItemTypeYouTube {
		t.Fatalf("Type = %v, want youtube", yt.Type)
	}
}

func TestResolveQueueItemRoute(t *testing.T) {
	local := playqueue.Item{Type: playqueue.ItemTypeLocal}
	if got := resolveQueueItemRoute(local, nil); got != queueRouteLocal {
		t.Fatalf("resolveQueueItemRoute(local) = %v, want local", got)
	}

	yt := playqueue.Item{Type: playqueue.ItemTypeYouTube}
	if got := resolveQueueItemRoute(yt, map[string]interface{}{"youtubePlaybackMode": "embed"}); got != queueRouteEmbed {
		t.Fatalf("resolveQueueItemRoute(youtube, embed) = %v, want embed", got)
	}
	if got := resolveQueueItemRoute(yt, map[string]interface{}{"youtubePlaybackMode": "stream"}); got != queueRouteStream {
		t.Fatalf("resolveQueueItemRoute(youtube, stream) = %v, want stream", got)
	}
	// Unset settings default to embed, matching resolveYoutubePlaybackMode's default.
	if got := resolveQueueItemRoute(yt, nil); got != queueRouteEmbed {
		t.Fatalf("resolveQueueItemRoute(youtube, unset) = %v, want embed (default)", got)
	}
}

func TestQueueSetActivatesQueueAndUpdatesState(t *testing.T) {
	newTempUserDataStore(t)
	app, emitted := newQueueTestApp(t)

	items := []map[string]interface{}{
		{"id": "a", "path": "/music/a.mp3", "type": "local", "title": "A"},
		{"id": "b", "path": "/music/b.mp3", "type": "local", "title": "B"},
	}
	// audioPlayer is nil (headless): starting playback fails, but that must
	// not panic and must not prevent the queue state itself from updating.
	_ = app.QueueSet(items, 1)

	if !app.ensureQueue().Active() {
		t.Fatalf("queue should be Active() after QueueSet")
	}
	current, ok := app.ensureQueue().CurrentItem()
	if !ok || current.ID != "b" {
		t.Fatalf("CurrentItem() = %+v, %v; want b, true", current, ok)
	}

	data, ok := lastEmit(emitted, "queue-state-changed")
	if !ok {
		t.Fatalf("expected queue-state-changed to be emitted")
	}
	payload, ok := data.(map[string]interface{})
	if !ok {
		t.Fatalf("queue-state-changed payload has unexpected type %T", data)
	}
	if payload["active"] != true {
		t.Fatalf("queue-state-changed payload active = %v, want true", payload["active"])
	}
	if payload["index"] != 1 {
		t.Fatalf("queue-state-changed payload index = %v, want 1", payload["index"])
	}
}

func TestQueueNextAdvancesAndEmitsState(t *testing.T) {
	newTempUserDataStore(t)
	app, emitted := newQueueTestApp(t)

	app.ensureQueue().SetQueue([]playqueue.Item{
		{ID: "a", Type: playqueue.ItemTypeLocal, Path: "/music/a.mp3"},
		{ID: "b", Type: playqueue.ItemTypeLocal, Path: "/music/b.mp3"},
	}, 0)
	*emitted = nil

	_ = app.QueueNext()

	current, ok := app.ensureQueue().CurrentItem()
	if !ok || current.ID != "b" {
		t.Fatalf("CurrentItem() after QueueNext = %+v, %v; want b, true", current, ok)
	}
	if !hasEmit(emitted, "queue-state-changed") {
		t.Fatalf("expected queue-state-changed to be emitted by QueueNext")
	}
}

func TestQueuePrevWrapsAtStart(t *testing.T) {
	newTempUserDataStore(t)
	app, _ := newQueueTestApp(t)

	app.ensureQueue().SetQueue([]playqueue.Item{
		{ID: "a", Type: playqueue.ItemTypeLocal, Path: "/music/a.mp3"},
		{ID: "b", Type: playqueue.ItemTypeLocal, Path: "/music/b.mp3"},
	}, 0)

	_ = app.QueuePrev()

	current, ok := app.ensureQueue().CurrentItem()
	if !ok || current.ID != "b" {
		t.Fatalf("CurrentItem() after QueuePrev wrap = %+v, %v; want b, true", current, ok)
	}
}

func TestHandlePlaybackFinishedLegacyWhenQueueInactive(t *testing.T) {
	newTempUserDataStore(t)
	app, emitted := newQueueTestApp(t)

	app.handlePlaybackFinished()

	if !hasEmit(emitted, "audio-playback-finished") {
		t.Fatalf("expected legacy audio-playback-finished to be emitted when queue is inactive")
	}
	if app.ensureQueue().Active() {
		t.Fatalf("queue must stay inactive when it was never handed a queue")
	}
}

func TestHandlePlaybackFinishedAdvancesQueueWhenActive(t *testing.T) {
	newTempUserDataStore(t)
	app, emitted := newQueueTestApp(t)

	app.ensureQueue().SetQueue([]playqueue.Item{
		{ID: "a", Type: playqueue.ItemTypeLocal, Path: "/music/a.mp3"},
		{ID: "b", Type: playqueue.ItemTypeLocal, Path: "/music/b.mp3"},
	}, 0)
	*emitted = nil

	app.handlePlaybackFinished()

	if hasEmit(emitted, "audio-playback-finished") {
		t.Fatalf("legacy audio-playback-finished must be suppressed while the Go queue is active (see progress/native-play-queue.md)")
	}
	data, ok := lastEmit(emitted, "queue-state-changed")
	if !ok {
		t.Fatalf("expected queue-state-changed to be emitted on auto-advance")
	}
	payload := data.(map[string]interface{})
	if payload["index"] != 1 {
		t.Fatalf("queue-state-changed index = %v, want 1 (advanced to b)", payload["index"])
	}
}

func TestStartQueueItemEmbedRouteDelegatesWithoutTouchingAudioPlayer(t *testing.T) {
	dir := newTempUserDataStore(t)
	_ = dir
	if err := store.Instance.Save("settings", map[string]interface{}{"youtubePlaybackMode": "embed"}); err != nil {
		t.Fatalf("seed settings: %v", err)
	}
	app, emitted := newQueueTestApp(t)

	item := playqueue.Item{ID: "y1", Type: playqueue.ItemTypeYouTube, Path: "https://youtu.be/xyz", Title: "YT"}
	if err := app.startQueueItem(item); err != nil {
		t.Fatalf("startQueueItem(embed) returned error: %v (must delegate, not touch nil audioPlayer)", err)
	}

	data, ok := lastEmit(emitted, "queue-play-embed")
	if !ok {
		t.Fatalf("expected queue-play-embed to be emitted for the embed route")
	}
	payload := data.(map[string]interface{})
	if payload["id"] != "y1" {
		t.Fatalf("queue-play-embed payload id = %v, want y1", payload["id"])
	}
}

// failingStarter returns a queueItemStarter (see app_queue.go's test seam)
// that fails for every item ID in failIDs and records every attempted item
// ID in order, so tests can assert both which items were skipped and how
// many attempts were made (bounding).
func failingStarter(failIDs map[string]bool) (func(playqueue.Item) error, *[]string) {
	var calls []string
	starter := func(item playqueue.Item) error {
		calls = append(calls, item.ID)
		if failIDs[item.ID] {
			return fmt.Errorf("fake start failure for %s", item.ID)
		}
		return nil
	}
	return starter, &calls
}

func TestHandlePlaybackFinishedSkipsFailingItemsUntilOneSucceeds(t *testing.T) {
	newTempUserDataStore(t)
	app, emitted := newQueueTestApp(t)

	starter, calls := failingStarter(map[string]bool{"b": true, "c": true})
	app.queueItemStarter = starter

	app.ensureQueue().SetQueue([]playqueue.Item{
		{ID: "a", Type: playqueue.ItemTypeLocal, Path: "/music/a.mp3"},
		{ID: "b", Type: playqueue.ItemTypeLocal, Path: "/music/b.mp3"},
		{ID: "c", Type: playqueue.ItemTypeLocal, Path: "/music/c.mp3"},
		{ID: "d", Type: playqueue.ItemTypeLocal, Path: "/music/d.mp3"},
	}, 0) // currently "playing" a
	*emitted = nil

	app.handlePlaybackFinished()

	if got := []string(*calls); len(got) != 3 || got[0] != "b" || got[1] != "c" || got[2] != "d" {
		t.Fatalf("start attempts = %v, want [b c d] (skip failing b and c, land on d)", got)
	}
	current, ok := app.ensureQueue().CurrentItem()
	if !ok || current.ID != "d" {
		t.Fatalf("CurrentItem() = %+v, %v; want d, true", current, ok)
	}
}

func TestHandlePlaybackFinishedGivesUpAfterFullPassAllFail(t *testing.T) {
	newTempUserDataStore(t)
	app, _ := newQueueTestApp(t)

	starter, calls := failingStarter(map[string]bool{"a": true, "b": true, "c": true})
	app.queueItemStarter = starter

	app.ensureQueue().SetQueue([]playqueue.Item{
		{ID: "a", Type: playqueue.ItemTypeLocal, Path: "/music/a.mp3"},
		{ID: "b", Type: playqueue.ItemTypeLocal, Path: "/music/b.mp3"},
		{ID: "c", Type: playqueue.ItemTypeLocal, Path: "/music/c.mp3"},
	}, 0)
	app.ensureQueue().SetLoopMode(playqueue.LoopAll)

	done := make(chan struct{})
	go func() {
		app.handlePlaybackFinished()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatalf("handlePlaybackFinished did not return — auto-advance skip must be bounded, not spin forever")
	}

	// Bounded by the queue length (3 items): must not retry beyond a single
	// full pass even though LoopAll means Advance() never itself stops.
	if got := len(*calls); got != 3 {
		t.Fatalf("start attempts = %d, want 3 (one full pass, all failing)", got)
	}
}

func TestQueueNextSurfacesErrorWithoutSkippingToNextItem(t *testing.T) {
	newTempUserDataStore(t)
	app, _ := newQueueTestApp(t)

	starter, calls := failingStarter(map[string]bool{"b": true})
	app.queueItemStarter = starter

	app.ensureQueue().SetQueue([]playqueue.Item{
		{ID: "a", Type: playqueue.ItemTypeLocal, Path: "/music/a.mp3"},
		{ID: "b", Type: playqueue.ItemTypeLocal, Path: "/music/b.mp3"},
		{ID: "c", Type: playqueue.ItemTypeLocal, Path: "/music/c.mp3"},
	}, 0)

	err := app.QueueNext()

	if err == nil {
		t.Fatalf("QueueNext() should surface the error for the explicitly requested item, got nil")
	}
	if got := []string(*calls); len(got) != 1 || got[0] != "b" {
		t.Fatalf("start attempts = %v, want [b] only — explicit QueueNext must not skip ahead", got)
	}
	current, ok := app.ensureQueue().CurrentItem()
	if !ok || current.ID != "b" {
		t.Fatalf("CurrentItem() = %+v, %v; want b (stays put on the failed item), true", current, ok)
	}
}
