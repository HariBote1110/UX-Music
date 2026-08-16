package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"ux-music-sidecar/internal/store"
)

// generateStreamTestFixture renders a long (well past what a naive
// "wait for the whole file" implementation could plausibly return in the
// time budget these tests use) sine-wave WAV via ffmpeg's lavfi source, so
// tests never depend on a checked-in binary asset.
func generateStreamTestFixture(t *testing.T, seconds int) string {
	t.Helper()
	dir := t.TempDir()
	out := filepath.Join(dir, "fixture.wav")
	cmd := exec.Command(ffmpegBinaryForTest(t),
		"-y",
		"-f", "lavfi",
		"-i", "sine=frequency=440:duration="+itoaTest(seconds),
		"-ar", "44100",
		"-ac", "2",
		out,
	)
	if out2, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("generate fixture: %v\n%s", err, out2)
	}
	return out
}

func itoaTest(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var digits []byte
	for n > 0 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
		n /= 10
	}
	if neg {
		digits = append([]byte{'-'}, digits...)
	}
	return string(digits)
}

func ffmpegBinaryForTest(t *testing.T) string {
	t.Helper()
	if p, err := exec.LookPath("ffmpeg"); err == nil {
		return p
	}
	if _, err := os.Stat("/opt/homebrew/bin/ffmpeg"); err == nil {
		return "/opt/homebrew/bin/ffmpeg"
	}
	t.Skip("ffmpeg not available on PATH; skipping streaming transcode test")
	return ""
}

// parseADTSHeaderForTest decodes just enough of the first ADTS frame header
// to verify format: sync word, MPEG-4 profile (AAC-LC = 1, i.e.
// ObjectType 2 minus 1), sampling-frequency index (4 = 44100Hz), and channel
// configuration (2 = stereo). Reference: ISO/IEC 13818-7 ADTS header layout,
// the same 7-byte fixed header /v1/remote/relay's own ADTS output uses.
func parseADTSHeaderForTest(b []byte) (profile, sampleRateIdx, channels int, ok bool) {
	if len(b) < 7 {
		return 0, 0, 0, false
	}
	if b[0] != 0xFF || b[1]&0xF0 != 0xF0 {
		return 0, 0, 0, false
	}
	profile = int(b[2]>>6) & 0x3
	sampleRateIdx = int(b[2]>>2) & 0xF
	channels = (int(b[2]&0x1) << 2) | (int(b[3]>>6) & 0x3)
	return profile, sampleRateIdx, channels, true
}

func seedStreamableSong(t *testing.T, id, path string) {
	t.Helper()
	if err := store.Instance.Save("library", []map[string]interface{}{
		{"id": id, "path": path, "title": "Stream Test Song", "type": "local"},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}
}

func TestRemoteFileHandler_StreamAAC_HeaderFormatMatchesRelay(t *testing.T) {
	requireFFmpegForTest(t)
	newTempRemoteStore(t)
	fixture := generateStreamTestFixture(t, 15)
	seedStreamableSong(t, "stream-1", fixture)

	req := httptest.NewRequest(http.MethodGet, "/v1/remote/file/stream-1?stream=aac", nil)
	rec := httptest.NewRecorder()
	remoteFileHandler(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", rec.Code, rec.Body.String())
	}
	if ct := rec.Header().Get("Content-Type"); ct != "audio/aac" {
		t.Fatalf("Content-Type = %q, want audio/aac", ct)
	}

	body := rec.Body.Bytes()
	if len(body) < 7 {
		t.Fatalf("expected at least one ADTS header worth of bytes, got %d", len(body))
	}
	profile, sampleRateIdx, channels, ok := parseADTSHeaderForTest(body)
	if !ok {
		t.Fatalf("expected valid ADTS sync word at start of stream, got %#x %#x", body[0], body[1])
	}
	if profile != 1 {
		t.Fatalf("expected AAC-LC profile (1), got %d", profile)
	}
	if sampleRateIdx != 4 {
		t.Fatalf("expected 44100Hz sample-rate index (4), got %d", sampleRateIdx)
	}
	if channels != 2 {
		t.Fatalf("expected stereo channel config (2), got %d", channels)
	}
}

func TestRemoteFileHandler_StreamAAC_FirstByteArrivesEarly(t *testing.T) {
	requireFFmpegForTest(t)
	newTempRemoteStore(t)
	// Long enough that "buffer the whole encode before responding" would be
	// clearly distinguishable from genuine streaming in the assertion below.
	fixture := generateStreamTestFixture(t, 30)
	seedStreamableSong(t, "stream-2", fixture)
	token := ensureDeviceAuthToken("dev_test_stream_early")

	srv := httptest.NewServer(NewLANHTTPHandler(NewApp()))
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/v1/remote/file/stream-2?stream=aac", nil)
	req.Header.Set("Authorization", "Bearer "+token)

	start := time.Now()
	resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatalf("GET stream: %v", err)
	}
	defer resp.Body.Close()

	buf := make([]byte, 1)
	if _, err := resp.Body.Read(buf); err != nil {
		t.Fatalf("read first byte: %v", err)
	}
	elapsed := time.Since(start)

	// A live encode starts writing ADTS frames essentially immediately.
	// Generously bounded so slow CI machines don't flake, while still
	// failing an implementation that waits for ffmpeg to finish first.
	if elapsed > 3*time.Second {
		t.Fatalf("first byte took %s; expected near-immediate start of streaming", elapsed)
	}
}

func TestRemoteFileHandler_StreamAAC_ClientDisconnectKillsFfmpeg(t *testing.T) {
	requireFFmpegForTest(t)
	newTempRemoteStore(t)
	fixture := generateStreamTestFixture(t, 30)
	seedStreamableSong(t, "stream-3", fixture)
	token := ensureDeviceAuthToken("dev_test_stream_disconnect")

	var mu sync.Mutex
	var pid int
	pidCh := make(chan int, 1)
	streamProcessStartedHook = func(p int) {
		mu.Lock()
		pid = p
		mu.Unlock()
		pidCh <- p
	}
	t.Cleanup(func() { streamProcessStartedHook = nil })

	srv := httptest.NewServer(NewLANHTTPHandler(NewApp()))
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/v1/remote/file/stream-3?stream=aac", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatalf("GET stream: %v", err)
	}

	select {
	case <-pidCh:
	case <-time.After(5 * time.Second):
		t.Fatal("ffmpeg never started (streamProcessStartedHook not invoked)")
	}

	buf := make([]byte, 1)
	if _, err := resp.Body.Read(buf); err != nil {
		t.Fatalf("read first byte: %v", err)
	}
	// Disconnect: the client walks away mid-stream.
	resp.Body.Close()

	mu.Lock()
	killedPID := pid
	mu.Unlock()

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if !processAliveForTest(killedPID) {
			return // reaped — success
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("ffmpeg process %d was still alive after client disconnect", killedPID)
}

func TestRemoteFileHandler_StreamAAC_NoLocalAudioReturns404(t *testing.T) {
	newTempRemoteStore(t)
	if err := store.Instance.Save("library", []map[string]interface{}{
		{"id": "yt-stream-1", "path": "https://www.youtube.com/watch?v=abc123", "title": "Embed-only Song", "type": "youtube"},
	}); err != nil {
		t.Fatalf("seed library: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/remote/file/yt-stream-1?stream=aac", nil)
	rec := httptest.NewRecorder()
	remoteFileHandler(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
	var errBody apiErrorBody
	if err := json.Unmarshal(rec.Body.Bytes(), &errBody); err != nil {
		t.Fatalf("decode error body: %v (body=%s)", err, rec.Body.String())
	}
	if errBody.Error.Code != "no_local_audio" {
		t.Fatalf("error code = %q, want %q", errBody.Error.Code, "no_local_audio")
	}
}

func TestRemoteFileHandler_StreamAAC_FfmpegMissingReturns500(t *testing.T) {
	newTempRemoteStore(t)
	seedStreamableSong(t, "stream-4", "/nonexistent/does-not-matter.flac")

	// This song's path won't stat, so the handler 404s before even reaching
	// the stream branch unless we point at a real (but tiny/empty) file.
	dir := t.TempDir()
	fakePath := filepath.Join(dir, "song.flac")
	if err := os.WriteFile(fakePath, []byte("not really audio"), 0o644); err != nil {
		t.Fatalf("write fake file: %v", err)
	}
	seedStreamableSong(t, "stream-4", fakePath)

	original := streamFfmpegPath
	streamFfmpegPath = func() (string, error) {
		return "", os.ErrNotExist
	}
	t.Cleanup(func() { streamFfmpegPath = original })

	req := httptest.NewRequest(http.MethodGet, "/v1/remote/file/stream-4?stream=aac", nil)
	rec := httptest.NewRecorder()
	remoteFileHandler(rec, req)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500 when ffmpeg is unavailable: %s", rec.Code, rec.Body.String())
	}
}
