package playqueue

import (
	"sync"
	"testing"
)

// TestConcurrentAccessIsRaceFree exercises Queue from many goroutines at
// once, mirroring the real call sites: Wails bindings (QueueSet/Next/Prev/
// Jump/SetShuffle/SetLoopMode/GetState all run on whatever goroutine Wails
// dispatches the call on), audio.Player's OnFinished callback (fired from
// the playback/decoder goroutine), the LAN remote command HTTP handler (one
// goroutine per request), and the OS media-key callback. Queue must be safe
// under `go test -race` for this mix.
func TestConcurrentAccessIsRaceFree(t *testing.T) {
	q := New()

	const goroutines = 8
	const opsPerGoroutine = 200

	baseItems := items("a", "b", "c", "d", "e")

	var wg sync.WaitGroup
	wg.Add(goroutines)
	for g := 0; g < goroutines; g++ {
		go func(seed int) {
			defer wg.Done()
			for i := 0; i < opsPerGoroutine; i++ {
				switch (seed + i) % 8 {
				case 0:
					q.SetQueue(baseItems, i%len(baseItems))
				case 1:
					q.Advance()
				case 2:
					q.Previous()
				case 3:
					q.JumpTo(i % len(baseItems))
				case 4:
					q.SetShuffle(i%2 == 0)
				case 5:
					q.SetLoopMode(LoopAll)
				case 6:
					q.CurrentItem()
				case 7:
					q.Snapshot()
				}
			}
		}(g)
	}
	wg.Wait()
}
