// server/app_queue.go wires pkg/playqueue (pure queue logic) into the App:
// Wails bindings for the frontend, the native OnFinished auto-advance hook,
// and next/prev interception for remote commands and OS media keys.
//
// The queue is opt-in (see pkg/playqueue's doc comment): until something
// calls QueueSet, a.ensureQueue().Active() is false and every call site in
// this file that checks it falls through to the pre-existing,
// renderer-driven behaviour unchanged. See progress/native-play-queue.md for
// the full design rationale, JS-parity notes and the double-count guard.
package server

import (
	"fmt"
	"math"
	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/internal/youtube"
	"ux-music-sidecar/pkg/playqueue"
)

// queueRoute mirrors src/renderer/js/features/youtube-embed-route.ts's
// resolveYouTubePlaybackRoute in Go.
type queueRoute string

const (
	queueRouteLocal  queueRoute = "local"
	queueRouteStream queueRoute = "stream"
	queueRouteEmbed  queueRoute = "embed"
)

// defaultQueueLoudnessTargetLUFS matches the frontend's default (see
// playSong() in playback-manager.ts: settings?.targetLoudness ?? -18.0).
const defaultQueueLoudnessTargetLUFS = -18.0

// ensureQueue returns the App's playback queue, lazily creating it. This
// keeps every method in this file safe to call on an App built directly as
// a struct literal (as many existing tests do) rather than only via
// NewApp().
func (a *App) ensureQueue() *playqueue.Queue {
	if a.queue == nil {
		a.queue = playqueue.New()
	}
	return a.queue
}

// songMapToQueueItem converts a song map (the shape used throughout
// server/, e.g. library entries and Wails call payloads) into a
// playqueue.Item. Mirrors playSong()'s own defaulting: a song with no
// explicit "type" but a "path" is treated as a local track.
func songMapToQueueItem(song map[string]interface{}) playqueue.Item {
	item := playqueue.Item{}
	if v, ok := song["id"].(string); ok {
		item.ID = v
	}
	if v, ok := song["path"].(string); ok {
		item.Path = v
	}
	if v, ok := song["title"].(string); ok {
		item.Title = v
	}
	if v, ok := song["artist"].(string); ok {
		item.Artist = v
	}
	if v, ok := song["album"].(string); ok {
		item.Album = v
	}
	if v, ok := song["artworkId"].(string); ok && v != "" {
		item.ArtworkID = v
	} else {
		item.ArtworkID = artworkIDForRemoteSong(song)
	}

	songType, _ := song["type"].(string)
	if songType == "" && item.Path != "" {
		songType = "local"
	}
	if songType == "youtube" {
		item.Type = playqueue.ItemTypeYouTube
	} else {
		item.Type = playqueue.ItemTypeLocal
	}
	return item
}

func songMapsToQueueItems(songs []map[string]interface{}) []playqueue.Item {
	items := make([]playqueue.Item, len(songs))
	for i, s := range songs {
		items[i] = songMapToQueueItem(s)
	}
	return items
}

func queueItemPayload(item playqueue.Item) map[string]interface{} {
	return map[string]interface{}{
		"id":        item.ID,
		"type":      string(item.Type),
		"path":      item.Path,
		"title":     item.Title,
		"artist":    item.Artist,
		"album":     item.Album,
		"artworkId": item.ArtworkID,
	}
}

func queueStatePayload(state playqueue.State) map[string]interface{} {
	items := make([]map[string]interface{}, len(state.Items))
	for i, it := range state.Items {
		items[i] = queueItemPayload(it)
	}
	return map[string]interface{}{
		"items":    items,
		"index":    state.Index,
		"shuffled": state.Shuffled,
		"loopMode": string(state.LoopMode),
		"active":   state.Active,
	}
}

// emitQueueState broadcasts the full queue snapshot as "queue-state-changed"
// so the (eventually thinned-down) frontend queue UI can mirror Go's state.
func (a *App) emitQueueState() {
	a.emit("queue-state-changed", queueStatePayload(a.ensureQueue().Snapshot()))
}

// resolveQueueItemRoute decides how a queue item should actually be played,
// matching resolveYouTubePlaybackRoute in youtube-embed-route.ts: non-
// YouTube items always play locally; YouTube items play through the
// official embed only when settings explicitly select it (default), and
// otherwise through the (unofficial) direct stream URL.
func resolveQueueItemRoute(item playqueue.Item, settings map[string]interface{}) queueRoute {
	if item.Type != playqueue.ItemTypeYouTube {
		return queueRouteLocal
	}
	if resolveYoutubePlaybackMode(settings) == "embed" {
		return queueRouteEmbed
	}
	return queueRouteStream
}

// resolveQueueLoudnessGain resolves the linear playback gain for a local
// queue item, mirroring resolveLocalPlaybackGain() in playback-gain.ts with
// forcePlay=true (i.e. it never blocks/waits for a pending loudness
// analysis — see progress/native-play-queue.md for why that gating is
// deliberately not replicated in Phase 1).
func (a *App) resolveQueueLoudnessGain(path string) float64 {
	targetLoudness := defaultQueueLoudnessTargetLUFS
	if settings, err := store.Instance.LoadMap("settings"); err == nil {
		if v, ok := settings["targetLoudness"].(float64); ok {
			targetLoudness = v
		}
	}

	savedRaw, _ := a.GetLoudnessValue(path)
	saved, ok := savedRaw.(float64)
	if !ok {
		return 1.0
	}
	gainDB := targetLoudness - saved
	return math.Pow(10, gainDB/20)
}

// applyQueueItemNowPlayingMetadata pushes OS Now Playing metadata for a
// queue item that has just started playing natively (local or resolved
// YouTube stream). It looks the item up in the library by ID to recover the
// artwork filename (song["artwork"]["full"]), matching
// updateOSNowPlayingMetadata()'s player.ts caller.
func (a *App) applyQueueItemNowPlayingMetadata(item playqueue.Item) {
	artworkRaw := ""
	if song, ok := remoteLibrarySongByID(item.ID); ok {
		if art, ok := song["artwork"].(map[string]interface{}); ok {
			if full, ok := art["full"].(string); ok {
				artworkRaw = full
			}
		}
	}
	_ = a.AudioSetNowPlayingMetadata(map[string]interface{}{
		"title":     item.Title,
		"artist":    item.Artist,
		"album":     item.Album,
		"artwork":   artworkRaw,
		"songId":    item.ID,
		"artworkId": item.ArtworkID,
	})
}

// incrementPlayCountForQueueItem counts a play for item, reusing the exact
// same IncrementPlayCount() used by the existing Wails binding (bridge.ts's
// musicApi.playbackStarted) so there is only ever one place that decides
// what counting a play means. Called once per native track start — see
// startQueueItem — matching the frontend's "count on start, not on finish"
// semantics (musicApi.playbackStarted is called right after playback
// actually begins, not from the audio-playback-finished handler).
func (a *App) incrementPlayCountForQueueItem(item playqueue.Item) {
	song, ok := remoteLibrarySongByID(item.ID)
	if !ok {
		song = map[string]interface{}{
			"path":   item.Path,
			"title":  item.Title,
			"artist": item.Artist,
			"album":  item.Album,
		}
	}
	a.IncrementPlayCount(song)
}

// startQueueItem starts native playback of item per its resolved route:
//   - embed: Go cannot play an official YouTube embed itself (Core Audio
//     process-tap territory, explicitly out of scope for this task) — it
//     emits "queue-play-embed" for the renderer to pick up and returns,
//     without touching audioPlayer at all.
//   - stream: resolves a direct googlevideo URL and plays it exactly like
//     any remote source (see pkg/audio.Player.Play's isRemoteSource path).
//   - local: resolves loudness gain and plays the file directly.
//
// For stream/local, Now Playing metadata is updated and the play is counted
// after a successful start.
func (a *App) startQueueItem(item playqueue.Item) error {
	settings, _ := store.Instance.LoadMap("settings")

	switch resolveQueueItemRoute(item, settings) {
	case queueRouteEmbed:
		a.emit("queue-play-embed", queueItemPayload(item))
		return nil

	case queueRouteStream:
		streamURL, err := youtube.GetYouTubeStreamURL(item.Path)
		if err != nil {
			fmt.Printf("[Queue] stream URL resolve failed for %s: %v\n", item.Path, err)
			return err
		}
		if err := a.AudioPlay(streamURL, 1.0); err != nil {
			return err
		}

	default: // queueRouteLocal
		gain := a.resolveQueueLoudnessGain(item.Path)
		if err := a.AudioPlay(item.Path, gain); err != nil {
			return err
		}
	}

	a.applyQueueItemNowPlayingMetadata(item)
	a.incrementPlayCountForQueueItem(item)
	return nil
}

// playQueueItem starts item via queueItemStarter if a test has injected one,
// otherwise via the real startQueueItem. Every call site that starts a
// specific queue item goes through this indirection so tests can observe
// and fail individual starts deterministically.
func (a *App) playQueueItem(item playqueue.Item) error {
	if a.queueItemStarter != nil {
		return a.queueItemStarter(item)
	}
	return a.startQueueItem(item)
}

// playCurrentQueueItem starts (or restarts) playback of whatever the queue
// currently points at, stopping native playback if the queue has no current
// item (e.g. it just ran off the end with loop off).
func (a *App) playCurrentQueueItem() error {
	item, ok := a.ensureQueue().CurrentItem()
	if !ok {
		_ = a.AudioStop()
		return nil
	}
	return a.playQueueItem(item)
}

// QueueSet replaces the native playback queue with items (following
// songMapToQueueItem's conversion) and starts playback of startIndex.
// Calling this activates the Go queue (Active() becomes true): from this
// point on, OnFinished auto-advance and remote/OS media next-prev are
// handled entirely in Go for this session (see handlePlaybackFinished,
// server/app_remote.go's remoteCommandHandler and app_media.go's
// initOSMediaControls).
func (a *App) QueueSet(items []map[string]interface{}, startIndex int) error {
	a.ensureQueue().SetQueue(songMapsToQueueItems(items), startIndex)
	a.emitQueueState()
	return a.playCurrentQueueItem()
}

// QueueNext advances the queue (honouring loop mode) and plays the result,
// or stops native playback if the queue ran off the end with loop off. This
// is the explicit, user/remote-triggered action: unlike the automatic
// OnFinished path (see autoAdvanceQueue), a failed start is surfaced to the
// caller as-is and the queue does NOT skip ahead to try another item.
func (a *App) QueueNext() error {
	item, ok := a.ensureQueue().Advance()
	a.emitQueueState()
	if !ok {
		_ = a.AudioStop()
		return nil
	}
	return a.playQueueItem(item)
}

// QueuePrev moves to the previous item (wrapping at the start, regardless
// of loop mode — see pkg/playqueue.Queue.Previous) and plays it. Like
// QueueNext, a failed start is surfaced to the caller without skipping.
func (a *App) QueuePrev() error {
	item, ok := a.ensureQueue().Previous()
	a.emitQueueState()
	if !ok {
		return nil
	}
	return a.playQueueItem(item)
}

// QueueJump moves directly to index in the current (possibly shuffled)
// order and plays it. An out-of-range index leaves the queue unchanged. A
// failed start is surfaced to the caller without skipping.
func (a *App) QueueJump(index int) error {
	item, ok := a.ensureQueue().JumpTo(index)
	a.emitQueueState()
	if !ok {
		return nil
	}
	return a.playQueueItem(item)
}

// QueueSetShuffle enables or disables shuffle (see
// pkg/playqueue.Queue.SetShuffle for the exact JS-parity semantics).
func (a *App) QueueSetShuffle(shuffled bool) {
	a.ensureQueue().SetShuffle(shuffled)
	a.emitQueueState()
}

// QueueSetLoopMode sets the loop mode directly ("off"/"all"/"one").
func (a *App) QueueSetLoopMode(mode string) {
	a.ensureQueue().SetLoopMode(playqueue.LoopMode(mode))
	a.emitQueueState()
}

// QueueGetState returns a full snapshot of the queue for polling/initial UI
// sync, mirroring what "queue-state-changed" carries.
func (a *App) QueueGetState() map[string]interface{} {
	return queueStatePayload(a.ensureQueue().Snapshot())
}

// handlePlaybackFinished is the audio.Player.SetOnFinished callback wired in
// Startup (app.go). It always updates OS playback state / Discord presence,
// exactly as before this change.
//
// When the Go queue is inactive (nothing has ever called QueueSet), it emits
// the legacy "audio-playback-finished" event and touches nothing else —
// behaviour is byte-for-byte what it was before Phase 1.
//
// When the Go queue is active, it deliberately does NOT emit
// "audio-playback-finished": that event's only renderer-side listener
// (player.ts) reads the renderer's OWN (now-stale, since Go is driving)
// state.playbackQueue/currentSongIndex to call musicApi.songFinished, which
// would misattribute the analysed-queue score adjustment to whatever the
// renderer still thinks is "current". Instead Go advances the queue itself
// and starts the next item via startQueueItem, which counts the play via
// IncrementPlayCount — the same call the frontend's musicApi.playbackStarted
// makes on a user-driven play. Because a Go-driven auto-advance never goes
// through the renderer's playSong()/musicApi.playbackStarted, there is no
// double count: exactly one of {JS playSong, Go startQueueItem} runs per
// track start. See progress/native-play-queue.md.
func (a *App) handlePlaybackFinished() {
	a.updateOSPlaybackState(false)
	a.pushDiscordPresence(false)

	q := a.ensureQueue()
	if !q.Active() {
		a.emit("audio-playback-finished", nil)
		return
	}

	a.autoAdvanceQueue()
}

// autoAdvanceQueue advances the Go queue and starts the result, exactly
// like QueueNext — except that when starting an item fails (e.g. its file
// was deleted mid-queue), it does not stall playback: it skips to the next
// item and tries again, instead of leaving the app silently stopped.
//
// This is bounded to at most one attempt per item currently in the queue
// (a "full pass"): after that many failed starts in a row it gives up,
// calls AudioStop and returns. The bound exists because Advance() alone
// does not guarantee forward progress — LoopAll wraps back to index 0 and
// LoopOne never leaves the current index — so without a cap a queue whose
// every item fails to start (e.g. every underlying file was deleted) would
// otherwise retry forever. Under LoopOne this means the same (failing) item
// may be attempted more than once before giving up; that is an accepted
// simplification (see progress/native-play-queue.md) rather than tracking
// which distinct items have already been tried.
//
// This bounded skip-and-retry is deliberately NOT used by QueueNext/
// QueuePrev/QueueJump/QueueSet: those are explicit, user/remote-triggered
// actions, and surfacing the error for exactly the item requested (rather
// than silently jumping to a different track) is the more correct
// behaviour there.
func (a *App) autoAdvanceQueue() {
	q := a.ensureQueue()

	attempts := len(q.Snapshot().Items)
	if attempts < 1 {
		attempts = 1
	}

	for i := 0; i < attempts; i++ {
		item, ok := q.Advance()
		a.emitQueueState()
		if !ok {
			_ = a.AudioStop()
			return
		}
		if err := a.playQueueItem(item); err != nil {
			fmt.Printf("[Queue] auto-advance play failed for %q, skipping: %v\n", item.Path, err)
			continue
		}
		return
	}

	fmt.Printf("[Queue] auto-advance exhausted %d attempt(s) with no successful start; stopping\n", attempts)
	_ = a.AudioStop()
}
