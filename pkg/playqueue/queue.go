// Package playqueue implements pure playback-queue logic (order, shuffle,
// loop mode, next/previous/jump) with no dependency on Wails, PortAudio, or
// any other server/audio package. It exists so the queue behaviour that
// previously lived only in the WebView's playback-manager.ts can be TDD'd
// and driven from Go while remaining trivially unit-testable.
//
// The semantics deliberately mirror src/renderer/js/features/playback-manager.ts
// (playNextSong / playPrevSong / toggleShuffle / toggleLoopMode) so that
// behaviour is unchanged for callers migrating from the JS queue. See
// progress/native-play-queue.md for a parity note and any deliberate
// divergences.
package playqueue

import (
	"math/rand"
)

// ItemType distinguishes how a queue item is played.
type ItemType string

const (
	ItemTypeLocal   ItemType = "local"
	ItemTypeYouTube ItemType = "youtube"
)

// LoopMode mirrors the JS PLAYBACK_MODES (NORMAL/LOOP_ALL/LOOP_ONE), renamed
// for clarity on the Go side.
type LoopMode string

const (
	LoopOff LoopMode = "off"
	LoopAll LoopMode = "all"
	LoopOne LoopMode = "one"
)

// Item is one entry in the playback queue. Path holds the local file path
// for ItemTypeLocal, or the original source URL for ItemTypeYouTube (from
// which a stream URL is resolved on demand — see server/app_queue.go).
type Item struct {
	ID        string   `json:"id"`
	Type      ItemType `json:"type"`
	Path      string   `json:"path"`
	Title     string   `json:"title"`
	Artist    string   `json:"artist"`
	Album     string   `json:"album"`
	ArtworkID string   `json:"artworkId"`
}

// State is a read-only snapshot of the queue, suitable for the
// "queue-state-changed" event payload and the QueueGetState binding.
type State struct {
	Items    []Item   `json:"items"`
	Index    int      `json:"index"`
	Shuffled bool     `json:"shuffled"`
	LoopMode LoopMode `json:"loopMode"`
	Active   bool     `json:"active"`
}

// Queue owns playback-queue order, current position, shuffle and loop mode.
// It is opt-in: a zero-value Queue (or one on which SetQueue has never been
// called) reports Active() == false, so callers can leave legacy
// (renderer-driven) behaviour untouched until something explicitly hands the
// queue a track list.
//
// All exported methods are safe for concurrent use.
type Queue struct {
	original []Item
	items    []Item
	index    int // -1 when nothing is current (empty queue, or ran off the end with loop off)
	shuffled bool
	loopMode LoopMode
	active   bool

	// shuffle reorders items in place. Defaults to a Fisher-Yates shuffle
	// backed by math/rand; overridable via NewWithShuffler for deterministic
	// tests.
	shuffle func(items []Item)
}

// New creates an empty Queue using a real random shuffle.
func New() *Queue {
	return NewWithShuffler(fisherYatesShuffle)
}

// NewWithShuffler creates an empty Queue using the given shuffle function
// in place of the default random shuffle. Intended for deterministic tests.
func NewWithShuffler(shuffle func(items []Item)) *Queue {
	return &Queue{
		index:    -1,
		loopMode: LoopOff,
		shuffle:  shuffle,
	}
}

func fisherYatesShuffle(items []Item) {
	for i := len(items) - 1; i > 0; i-- {
		j := rand.Intn(i + 1)
		items[i], items[j] = items[j], items[i]
	}
}

// SetQueue replaces the queue contents with items (the "original", unshuffled
// order) and starts at startIndex. If shuffle is currently enabled, the
// queue is immediately reshuffled with items[startIndex] pinned to the
// front — matching playSong()'s behaviour when handed a fresh sourceList
// while shuffled. Calling SetQueue activates the queue (Active() becomes
// true) regardless of prior state.
func (q *Queue) SetQueue(items []Item, startIndex int) {
	q.original = cloneItems(items)
	q.active = true

	if q.shuffled {
		q.items = shuffledFrom(q.original, startIndex, q.shuffle)
		q.index = boolToIndex(len(q.items) > 0)
		return
	}

	q.items = cloneItems(items)
	if startIndex < 0 || startIndex >= len(q.items) {
		q.index = -1
		return
	}
	q.index = startIndex
}

// boolToIndex is a tiny helper: true -> 0, false -> -1.
func boolToIndex(nonEmpty bool) int {
	if nonEmpty {
		return 0
	}
	return -1
}

// shuffledFrom builds a shuffled copy of source with source[pinIndex] moved
// to the front (unless pinIndex is out of range, in which case the whole
// list is shuffled with no pinned item), matching playSong()'s shuffle
// branch and toggleShuffle()'s "keep current song first" behaviour.
func shuffledFrom(source []Item, pinIndex int, shuffle func([]Item)) []Item {
	if len(source) == 0 {
		return nil
	}

	var pinned *Item
	rest := make([]Item, 0, len(source))
	if pinIndex >= 0 && pinIndex < len(source) {
		p := source[pinIndex]
		pinned = &p
		for i, it := range source {
			if i != pinIndex {
				rest = append(rest, it)
			}
		}
	} else {
		rest = append(rest, source...)
	}

	shuffle(rest)

	if pinned == nil {
		return rest
	}
	result := make([]Item, 0, len(source))
	result = append(result, *pinned)
	result = append(result, rest...)
	return result
}

func cloneItems(items []Item) []Item {
	out := make([]Item, len(items))
	copy(out, items)
	return out
}

// Active reports whether the Go queue currently owns playback control (i.e.
// SetQueue has been called at least once). Legacy renderer-driven behaviour
// should remain untouched while this is false.
func (q *Queue) Active() bool {
	return q.active
}

// Shuffled reports whether shuffle is currently enabled.
func (q *Queue) Shuffled() bool {
	return q.shuffled
}

// LoopMode returns the current loop mode.
func (q *Queue) LoopMode() LoopMode {
	return q.loopMode
}

// SetLoopMode sets the loop mode directly (off/all/one). Unlike the JS
// toggleLoopMode(), which only cycles to the next mode, this is a direct
// setter — callers wanting a cycling toggle should read LoopMode() and pick
// the next value themselves. Unrecognised values are ignored.
func (q *Queue) SetLoopMode(mode LoopMode) {
	switch mode {
	case LoopOff, LoopAll, LoopOne:
		q.loopMode = mode
	}
}

// CurrentItem returns the item at the current position, or ok=false if the
// queue is empty or the position has run off the end.
func (q *Queue) CurrentItem() (Item, bool) {
	if q.index < 0 || q.index >= len(q.items) {
		return Item{}, false
	}
	return q.items[q.index], true
}

// Advance moves to the next item, honouring loop mode:
//   - LoopOne: stays on (returns) the current item unchanged.
//   - otherwise, past the end of the queue: LoopAll wraps to index 0; plain
//     off stops (ok=false, current position cleared) — matching
//     playNextSong()'s stop-at-end behaviour.
func (q *Queue) Advance() (Item, bool) {
	if len(q.items) == 0 {
		return Item{}, false
	}

	if q.loopMode == LoopOne {
		return q.CurrentItem()
	}

	next := q.index + 1
	if next >= len(q.items) {
		if q.loopMode == LoopAll {
			next = 0
		} else {
			q.index = -1
			return Item{}, false
		}
	}
	q.index = next
	return q.CurrentItem()
}

// Previous moves to the previous item, wrapping to the last item when
// already at index 0. Unlike Advance, loop mode (including LoopOne) has no
// effect here — this matches playPrevSong(), which always steps back
// regardless of the loop setting.
func (q *Queue) Previous() (Item, bool) {
	if len(q.items) == 0 {
		return Item{}, false
	}

	prev := q.index - 1
	if prev < 0 {
		prev = len(q.items) - 1
	}
	q.index = prev
	return q.CurrentItem()
}

// JumpTo moves directly to the given index in the current (possibly
// shuffled) order. An out-of-range index leaves the queue position
// unchanged and returns ok=false.
func (q *Queue) JumpTo(index int) (Item, bool) {
	if index < 0 || index >= len(q.items) {
		return Item{}, false
	}
	q.index = index
	return q.CurrentItem()
}

// SetShuffle enables or disables shuffle, matching toggleShuffle():
//   - enabling: reshuffles from the original (unshuffled) order with the
//     current item pinned to the front (new index 0); if there is no
//     current item, the position becomes empty (-1).
//   - disabling: restores the original order and relocates the current item
//     within it by ID; if the current item is no longer present, the
//     position becomes empty (-1).
func (q *Queue) SetShuffle(shuffled bool) {
	if shuffled == q.shuffled {
		return
	}

	current, hasCurrent := q.CurrentItem()
	q.shuffled = shuffled

	if shuffled {
		pinIndex := -1
		if hasCurrent {
			for i, it := range q.original {
				if it.ID == current.ID {
					pinIndex = i
					break
				}
			}
		}
		q.items = shuffledFrom(q.original, pinIndex, q.shuffle)
		if hasCurrent && len(q.items) > 0 {
			q.index = 0
		} else {
			q.index = -1
		}
		return
	}

	q.items = cloneItems(q.original)
	if hasCurrent {
		q.index = -1
		for i, it := range q.items {
			if it.ID == current.ID {
				q.index = i
				break
			}
		}
	} else {
		q.index = -1
	}
}

// Snapshot returns a read-only copy of the current queue state, suitable
// for emitting to the frontend or answering QueueGetState.
func (q *Queue) Snapshot() State {
	return State{
		Items:    cloneItems(q.items),
		Index:    q.index,
		Shuffled: q.shuffled,
		LoopMode: q.loopMode,
		Active:   q.active,
	}
}
