package server

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"ux-music-sidecar/internal/config"
	"ux-music-sidecar/internal/store"
	"ux-music-sidecar/internal/uxsync"
)

// newTempUserDataStore は一時ディレクトリを userDataPath に差し込み、空の
// store.Instance を用意したうえで、テスト終了時に直前のグローバル値へ戻す。
//
// config.Instance / store.Instance はプロセスグローバルであり、t.TempDir() の
// ディレクトリはテスト終了時に削除される。復元しないと後続テストが削除済みの
// パスを指した config をそのまま引き継ぎ、実行順に依存した失敗になる。
func newTempUserDataStore(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	prevPath := config.GetUserDataPath()
	prevStore := store.Instance
	config.SetUserDataPath(dir)
	store.Instance = &store.Store{}
	t.Cleanup(func() {
		config.SetUserDataPath(prevPath)
		store.Instance = prevStore
	})
	return dir
}

// newTempSyncStore は sync 系テスト向けの別名。実体は newTempUserDataStore。
func newTempSyncStore(t *testing.T) string {
	t.Helper()
	return newTempUserDataStore(t)
}

// syncExpectedArtworkKeys は取り込み済みトラックが必ず持つべき artwork キー。
// 本番側 saveSyncArtworkAsset が返すマップと一致させること。
var syncExpectedArtworkKeys = []string{"full", "thumbnail"}

// requireSyncArtworkFiles は track["artwork"] が full / thumbnail の 2 キーを
// 持ち、いずれも空でない文字列で、実ファイルが存在することを検証する。
//
// 以前は `artwork, _ := track["artwork"].(map[string]interface{})` の後に
// `artwork["full"] == ""` で判定していたが、キー欠落時の値は string ではなく
// interface{}(nil) なので比較は常に false になり、続く range も 0 回で
// ファイル存在チェックごと素通りしていた。構造的に失敗しうる形へ直す。
func requireSyncArtworkFiles(t *testing.T, track map[string]interface{}, context string) {
	t.Helper()
	artwork, ok := track["artwork"].(map[string]interface{})
	if !ok {
		t.Fatalf("%s: expected artwork map[string]interface{}, got %#v", context, track["artwork"])
	}
	if len(artwork) != len(syncExpectedArtworkKeys) {
		t.Fatalf("%s: expected artwork keys %v exactly, got %#v", context, syncExpectedArtworkKeys, artwork)
	}
	for _, key := range syncExpectedArtworkKeys {
		name, ok := artwork[key].(string)
		if !ok || name == "" {
			t.Fatalf("%s: expected non-empty string artwork[%q], got %#v", context, key, artwork[key])
		}
		path := filepath.Join(config.GetUserDataPath(), "Artworks", name)
		if key == "thumbnail" {
			path = filepath.Join(config.GetUserDataPath(), "Artworks", "thumbnails", name)
		}
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("%s: expected %s artwork file %q: %v", context, key, path, err)
		}
	}
}

// handlerObserver は httptest ハンドラーゴルーチンからの観測結果を溜める。
// ハンドラー内で t.Fatalf を呼ぶと FailNow がテスト外ゴルーチンで走り、応答を
// 返さないままハンドラーが終了して無関係なタイムアウト失敗に化けるため、
// 記録だけ行いテストゴルーチン側で assertNoErrors する。
type handlerObserver struct {
	mu     sync.Mutex
	errors []string
}

func (o *handlerObserver) errorf(format string, args ...interface{}) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.errors = append(o.errors, fmt.Sprintf(format, args...))
}

func (o *handlerObserver) assertNoErrors(t *testing.T) {
	t.Helper()
	o.mu.Lock()
	defer o.mu.Unlock()
	if len(o.errors) == 0 {
		return
	}
	for _, message := range o.errors {
		t.Errorf("handler goroutine: %s", message)
	}
	t.FailNow()
}

// syncRequestCounter はハンドラーゴルーチンが書き込みテストゴルーチンが読む
// リクエスト数を排他制御付きで保持する（素の map だと -race で競合検出される）。
type syncRequestCounter struct {
	mu     sync.Mutex
	counts map[string]int
}

func newSyncRequestCounter() *syncRequestCounter {
	return &syncRequestCounter{counts: map[string]int{}}
}

func (c *syncRequestCounter) inc(key string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.counts[key]++
}

func (c *syncRequestCounter) get(key string) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.counts[key]
}

func (c *syncRequestCounter) snapshot() map[string]int {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make(map[string]int, len(c.counts))
	for key, value := range c.counts {
		out[key] = value
	}
	return out
}

// syncValueRecorder はハンドラーゴルーチンが記録しテストゴルーチンが読む
// 任意の観測値を排他制御付きで保持する。
type syncValueRecorder struct {
	mu     sync.Mutex
	values map[string]interface{}
}

func newSyncValueRecorder() *syncValueRecorder {
	return &syncValueRecorder{values: map[string]interface{}{}}
}

func (r *syncValueRecorder) set(key string, value interface{}) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.values[key] = value
}

func (r *syncValueRecorder) get(key string) interface{} {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.values[key]
}

func (r *syncValueRecorder) getString(key string) string {
	value, _ := r.get(key).(string)
	return value
}

func TestSyncLibraryEventsPushStoresChildPlayEventsAndReturnsAcks(t *testing.T) {
	newTempSyncStore(t)
	payload := []byte(`{
		"deviceId": "macbook-air",
		"playEvents": [
			{
				"eventId": "evt_air_0001",
				"trackId": "trk_1",
				"deviceId": "macbook-air",
				"deviceSequence": 1,
				"playedAt": "2026-06-08T12:00:00Z",
				"countedAt": "2026-06-08T12:03:00Z",
				"durationPlayedMs": 180000,
				"completed": true
			},
			{
				"eventId": "evt_air_0002",
				"trackId": "trk_1",
				"deviceId": "macbook-air",
				"deviceSequence": 2,
				"playedAt": "2026-06-08T12:10:00Z",
				"countedAt": "2026-06-08T12:13:00Z",
				"durationPlayedMs": 180000,
				"completed": true
			}
		]
	}`)

	first := postSyncLibraryEvents(t, payload)
	second := postSyncLibraryEvents(t, payload)
	events := readStoredSyncPlayEvents(t)
	counts := uxsync.PlayCountsByTrack(events)

	if first.Accepted != 2 || second.Accepted != 2 {
		t.Fatalf("expected both requests to accept 2 events, got first=%d second=%d", first.Accepted, second.Accepted)
	}
	if first.Ack.DeviceID != "macbook-air" || first.Ack.MaxDeviceSequence != 2 {
		t.Fatalf("unexpected ack: %#v", first.Ack)
	}
	if len(events) != 2 {
		t.Fatalf("expected store to keep 2 unique events after resend, got %d", len(events))
	}
	if counts["trk_1"].Count != 2 {
		t.Fatalf("expected 2 counted plays, got %d", counts["trk_1"].Count)
	}
}

func TestSyncLibraryEventsRejectsInvalidMethod(t *testing.T) {
	newTempSyncStore(t)
	req := httptest.NewRequest(http.MethodGet, "/sync/library/events", nil)
	rec := httptest.NewRecorder()

	(&App{}).syncLibraryEventsHandler(rec, req)

	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected status %d, got %d", http.StatusMethodNotAllowed, rec.Code)
	}
}

func TestSyncLibraryEventsEmitsUpdatedPlayCountsAfterApplyingEvents(t *testing.T) {
	newTempSyncStore(t)
	songPath := filepath.Join(t.TempDir(), "host.flac")
	if err := store.Instance.Save("library", []map[string]interface{}{
		{"id": "host-track-1", "path": songPath, "title": "Host Song"},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}
	payload := []byte(`{
		"deviceId": "dev_portable",
		"playEvents": [
			{
				"eventId": "evt_portable_emit_1",
				"trackId": "host-track-1",
				"deviceId": "dev_portable",
				"deviceSequence": 1,
				"playedAt": "2026-06-09T07:20:00Z",
				"countedAt": "2026-06-09T07:23:00Z",
				"durationPlayedMs": 180000,
				"completed": true
			}
		]
	}`)
	var emitted []struct {
		name string
		data interface{}
	}
	app := &App{
		ctx: context.Background(),
		playCountsEmitter: func(_ context.Context, name string, data interface{}) {
			emitted = append(emitted, struct {
				name string
				data interface{}
			}{name: name, data: data})
		},
	}
	req := httptest.NewRequest(http.MethodPost, "/sync/library/events", bytes.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	app.syncLibraryEventsHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status %d: %s", rec.Code, rec.Body.String())
	}
	if len(emitted) != 1 || emitted[0].name != "play-counts-updated" {
		t.Fatalf("expected one play-counts-updated emit, got %#v", emitted)
	}
	counts, _ := emitted[0].data.(map[string]interface{})
	entry, _ := counts[songPath].(map[string]interface{})
	if entry == nil || entry["count"] != float64(1) {
		t.Fatalf("expected emitted playcounts to include applied count, got %#v", emitted[0].data)
	}
}

func postSyncLibraryEvents(t *testing.T, payload []byte) syncLibraryEventsResponse {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/sync/library/events", bytes.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	(&App{}).syncLibraryEventsHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status %d: %s", rec.Code, rec.Body.String())
	}
	var response syncLibraryEventsResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	return response
}

func readStoredSyncPlayEvents(t *testing.T) []uxsync.PlayEvent {
	t.Helper()
	path := filepath.Join(config.Instance.GetUserDataPath(), syncPlayEventsStoreName+".json")
	bytes, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read sync events store: %v", err)
	}
	var events []uxsync.PlayEvent
	if err := json.Unmarshal(bytes, &events); err != nil {
		t.Fatalf("decode sync events store: %v", err)
	}
	return events
}
