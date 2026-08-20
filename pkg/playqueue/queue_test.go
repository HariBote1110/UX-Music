package playqueue

import "testing"

func items(ids ...string) []Item {
	out := make([]Item, len(ids))
	for i, id := range ids {
		out[i] = Item{ID: id, Type: ItemTypeLocal, Path: "/music/" + id + ".mp3", Title: id}
	}
	return out
}

func TestSetQueueNoShuffleSetsCurrentItem(t *testing.T) {
	q := New()
	q.SetQueue(items("a", "b", "c"), 1)

	current, ok := q.CurrentItem()
	if !ok || current.ID != "b" {
		t.Fatalf("CurrentItem() = %+v, %v; want b, true", current, ok)
	}
	if !q.Active() {
		t.Fatalf("Active() = false after SetQueue; want true")
	}
}

func TestAdvanceMovesToNextItem(t *testing.T) {
	q := New()
	q.SetQueue(items("a", "b", "c"), 0)

	next, ok := q.Advance()
	if !ok || next.ID != "b" {
		t.Fatalf("Advance() = %+v, %v; want b, true", next, ok)
	}
	current, _ := q.CurrentItem()
	if current.ID != "b" {
		t.Fatalf("CurrentItem() after Advance = %+v; want b", current)
	}
}

func TestAdvanceAtEndWithLoopOffStops(t *testing.T) {
	q := New()
	q.SetQueue(items("a", "b"), 1)
	q.SetLoopMode(LoopOff)

	_, ok := q.Advance()
	if ok {
		t.Fatalf("Advance() at end with LoopOff should return ok=false")
	}
	if _, ok := q.CurrentItem(); ok {
		t.Fatalf("CurrentItem() after end-of-queue stop should be ok=false")
	}
}

func TestAdvanceAtEndWithLoopAllWraps(t *testing.T) {
	q := New()
	q.SetQueue(items("a", "b"), 1)
	q.SetLoopMode(LoopAll)

	next, ok := q.Advance()
	if !ok || next.ID != "a" {
		t.Fatalf("Advance() with LoopAll at end = %+v, %v; want a, true", next, ok)
	}
}

func TestAdvanceWithLoopOneRepeatsCurrent(t *testing.T) {
	q := New()
	q.SetQueue(items("a", "b", "c"), 1)
	q.SetLoopMode(LoopOne)

	next, ok := q.Advance()
	if !ok || next.ID != "b" {
		t.Fatalf("Advance() with LoopOne = %+v, %v; want b (repeat), true", next, ok)
	}
}

func TestPreviousWrapsAtStart(t *testing.T) {
	q := New()
	q.SetQueue(items("a", "b", "c"), 0)

	prev, ok := q.Previous()
	if !ok || prev.ID != "c" {
		t.Fatalf("Previous() at index 0 = %+v, %v; want c (wrap), true", prev, ok)
	}
}

func TestPreviousMovesBackNormally(t *testing.T) {
	q := New()
	q.SetQueue(items("a", "b", "c"), 2)

	prev, ok := q.Previous()
	if !ok || prev.ID != "b" {
		t.Fatalf("Previous() = %+v, %v; want b, true", prev, ok)
	}
}

func TestPreviousIgnoresLoopOne(t *testing.T) {
	// JS playPrevSong does not special-case LOOP_ONE; it always steps back.
	q := New()
	q.SetQueue(items("a", "b", "c"), 1)
	q.SetLoopMode(LoopOne)

	prev, ok := q.Previous()
	if !ok || prev.ID != "a" {
		t.Fatalf("Previous() with LoopOne = %+v, %v; want a, true", prev, ok)
	}
}

func TestJumpTo(t *testing.T) {
	q := New()
	q.SetQueue(items("a", "b", "c"), 0)

	item, ok := q.JumpTo(2)
	if !ok || item.ID != "c" {
		t.Fatalf("JumpTo(2) = %+v, %v; want c, true", item, ok)
	}

	if _, ok := q.JumpTo(99); ok {
		t.Fatalf("JumpTo(99) out of range should return ok=false")
	}
	// Out-of-range jump must not disturb the current position.
	current, _ := q.CurrentItem()
	if current.ID != "c" {
		t.Fatalf("CurrentItem() after failed JumpTo = %+v; want unchanged c", current)
	}
}

func TestSetShuffleTruePreservesCurrentAtFront(t *testing.T) {
	q := NewWithShuffler(func(items []Item) {
		// Reverse instead of random shuffle, for a deterministic test.
		for i, j := 0, len(items)-1; i < j; i, j = i+1, j-1 {
			items[i], items[j] = items[j], items[i]
		}
	})
	q.SetQueue(items("a", "b", "c", "d"), 2) // current = c

	q.SetShuffle(true)

	if !q.Shuffled() {
		t.Fatalf("Shuffled() = false after SetShuffle(true)")
	}
	current, ok := q.CurrentItem()
	if !ok || current.ID != "c" {
		t.Fatalf("CurrentItem() after shuffle = %+v, %v; want c at front, true", current, ok)
	}
	snap := q.Snapshot()
	if snap.Index != 0 {
		t.Fatalf("Snapshot().Index = %d; want 0", snap.Index)
	}
	if len(snap.Items) != 4 {
		t.Fatalf("Snapshot().Items length = %d; want 4", len(snap.Items))
	}
	// Reversed remaining order (a,b,d minus c -> a,b,d reversed -> d,b,a), c unshifted to front.
	wantOrder := []string{"c", "d", "b", "a"}
	for i, id := range wantOrder {
		if snap.Items[i].ID != id {
			t.Fatalf("Snapshot().Items[%d].ID = %s; want %s (order=%v)", i, snap.Items[i].ID, id, snap.Items)
		}
	}
}

func TestSetShuffleFalseRestoresOriginalOrder(t *testing.T) {
	q := NewWithShuffler(func(items []Item) {
		for i, j := 0, len(items)-1; i < j; i, j = i+1, j-1 {
			items[i], items[j] = items[j], items[i]
		}
	})
	q.SetQueue(items("a", "b", "c", "d"), 2) // current = c
	q.SetShuffle(true)
	q.SetShuffle(false)

	if q.Shuffled() {
		t.Fatalf("Shuffled() = true after SetShuffle(false)")
	}
	snap := q.Snapshot()
	wantOrder := []string{"a", "b", "c", "d"}
	for i, id := range wantOrder {
		if snap.Items[i].ID != id {
			t.Fatalf("Snapshot().Items[%d].ID = %s; want %s", i, snap.Items[i].ID, id)
		}
	}
	if snap.Index != 2 {
		t.Fatalf("Snapshot().Index = %d; want 2 (c's index in original order)", snap.Index)
	}
}

func TestSetLoopModeCycles(t *testing.T) {
	q := New()
	if got := q.LoopMode(); got != LoopOff {
		t.Fatalf("default LoopMode() = %v; want LoopOff", got)
	}
	q.SetLoopMode(LoopAll)
	if got := q.LoopMode(); got != LoopAll {
		t.Fatalf("LoopMode() = %v; want LoopAll", got)
	}
}

func TestEmptyQueueIsInert(t *testing.T) {
	q := New()
	if _, ok := q.CurrentItem(); ok {
		t.Fatalf("CurrentItem() on empty queue should be ok=false")
	}
	if _, ok := q.Advance(); ok {
		t.Fatalf("Advance() on empty queue should be ok=false")
	}
	if _, ok := q.Previous(); ok {
		t.Fatalf("Previous() on empty queue should be ok=false")
	}
	if q.Active() {
		t.Fatalf("Active() on a never-set queue should be false")
	}
}

func TestSnapshotReflectsState(t *testing.T) {
	q := New()
	q.SetQueue(items("a", "b"), 0)
	q.SetLoopMode(LoopAll)

	snap := q.Snapshot()
	if !snap.Active {
		t.Fatalf("Snapshot().Active = false; want true")
	}
	if snap.LoopMode != LoopAll {
		t.Fatalf("Snapshot().LoopMode = %v; want LoopAll", snap.LoopMode)
	}
	if snap.Index != 0 {
		t.Fatalf("Snapshot().Index = %d; want 0", snap.Index)
	}
	if len(snap.Items) != 2 {
		t.Fatalf("Snapshot().Items length = %d; want 2", len(snap.Items))
	}
}
