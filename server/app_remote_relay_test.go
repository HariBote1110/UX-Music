package server

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os/exec"
	"testing"
	"time"
)

// chanRelayPCMSource is a synthetic PCMSource for tests: pushed chunks are
// delivered in order and ReadPCM blocks until one is pushed or the source is
// closed. It lets tests drive the relay engine without Core Audio hardware.
type chanRelayPCMSource struct {
	ch         chan []float32
	sampleRate int
	channels   int
}

func newChanRelayPCMSource(sampleRate, channels int) *chanRelayPCMSource {
	return &chanRelayPCMSource{ch: make(chan []float32, 64), sampleRate: sampleRate, channels: channels}
}

func (s *chanRelayPCMSource) ReadPCM(dst []float32) (int, bool) {
	chunk, ok := <-s.ch
	if !ok {
		return 0, false
	}
	return copy(dst, chunk), true
}

func (s *chanRelayPCMSource) SampleRate() int { return s.sampleRate }
func (s *chanRelayPCMSource) Channels() int   { return s.channels }

func (s *chanRelayPCMSource) push(chunk []float32) { s.ch <- chunk }
func (s *chanRelayPCMSource) close()               { close(s.ch) }

// sineChunk generates one chunk of a 440Hz sine wave for the given number of
// interleaved mono frames, starting at phase offset.
func sineChunk(frames int, phase *float64, sampleRate int) []float32 {
	const freq = 440.0
	out := make([]float32, frames)
	for i := 0; i < frames; i++ {
		out[i] = float32(0.2 * sinApprox(*phase))
		*phase += 2 * 3.14159265358979 * freq / float64(sampleRate)
	}
	return out
}

// sinApprox avoids importing math just for a test helper's sine; a real
// sine isn't required, only a bounded, varying signal for ffmpeg to encode.
func sinApprox(x float64) float64 {
	// Wrap into [-pi, pi] then use a cheap cubic approximation.
	for x > 3.14159265358979 {
		x -= 2 * 3.14159265358979
	}
	for x < -3.14159265358979 {
		x += 2 * 3.14159265358979
	}
	return 1.27323954*x - 0.405284735*x*x*sign(x)
}

func sign(x float64) float64 {
	if x < 0 {
		return -1
	}
	return 1
}

func requireFFmpegForTest(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		if _, statErr := exec.LookPath("/opt/homebrew/bin/ffmpeg"); statErr != nil {
			t.Skip("ffmpeg not available on PATH; skipping relay encode test")
		}
	}
}

func withServerMode(t *testing.T, mode string) {
	t.Helper()
	original := CurrentServerMode()
	SetServerMode(mode)
	t.Cleanup(func() { SetServerMode(original) })
}

func TestRemoteRelayHandler_RequiresDeviceAuth(t *testing.T) {
	newTempRemoteStore(t)
	withServerMode(t, ModeGUI)

	handler := NewLANHTTPHandler(NewApp())
	req := httptest.NewRequest(http.MethodGet, "/v1/remote/relay", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 without device token, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestRemoteRelayHandler_HeadlessModeReturns404(t *testing.T) {
	newTempRemoteStore(t)
	withServerMode(t, ModeHeadless)
	token := ensureDeviceAuthToken("dev_test_headless")

	handler := NewLANHTTPHandler(NewApp())
	req := httptest.NewRequest(http.MethodGet, "/v1/remote/relay", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("expected 404 in headless mode, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestRemoteRelayHandler_NoActiveSourceReturns409(t *testing.T) {
	newTempRemoteStore(t)
	withServerMode(t, ModeGUI)
	remoteRelay.Stop() // ensure no leftover state from another test
	token := ensureDeviceAuthToken("dev_test_no_source")

	handler := NewLANHTTPHandler(NewApp())
	req := httptest.NewRequest(http.MethodGet, "/v1/remote/relay", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusConflict {
		t.Fatalf("expected 409 when no relay source is active, got %d: %s", rec.Code, rec.Body.String())
	}
	var body apiErrorBody
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("expected JSON error body: %v", err)
	}
	if body.Error.Message == "" {
		t.Fatalf("expected non-empty error message, got %#v", body)
	}
}

func TestRemoteRelayEngine_SingleClientReceivesADTSBytes(t *testing.T) {
	requireFFmpegForTest(t)
	newTempRemoteStore(t)
	withServerMode(t, ModeGUI)
	token := ensureDeviceAuthToken("dev_test_single")

	source := newChanRelayPCMSource(44100, 1)
	if err := remoteRelay.Start(source, "Test Song", "https://example.com/thumb.jpg"); err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(remoteRelay.Stop)

	go func() {
		phase := 0.0
		for i := 0; i < 40; i++ {
			source.push(sineChunk(2048, &phase, 44100))
			time.Sleep(5 * time.Millisecond)
		}
	}()

	srv := httptest.NewServer(NewLANHTTPHandler(NewApp()))
	defer srv.Close()

	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/v1/remote/relay", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatalf("GET /v1/remote/relay: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "audio/aac" {
		t.Fatalf("expected Content-Type audio/aac, got %q", ct)
	}

	buf := make([]byte, 4096)
	total := 0
	deadline := time.Now().Add(5 * time.Second)
	for total < 8 && time.Now().Before(deadline) {
		n, err := resp.Body.Read(buf[total:])
		total += n
		if err != nil && err != io.EOF {
			break
		}
		if n == 0 {
			time.Sleep(10 * time.Millisecond)
		}
	}
	if total == 0 {
		t.Fatalf("expected to receive ADTS bytes from relay, got none")
	}
	// ADTS frames start with the 12-bit sync word 0xFFF.
	if buf[0] != 0xFF || buf[1]&0xF0 != 0xF0 {
		t.Fatalf("expected ADTS sync word at start of stream, got %#x %#x", buf[0], buf[1])
	}
}

func TestRemoteRelayEngine_MultipleConcurrentClientsBothReceiveBytes(t *testing.T) {
	requireFFmpegForTest(t)
	newTempRemoteStore(t)
	withServerMode(t, ModeGUI)
	token := ensureDeviceAuthToken("dev_test_multi")

	source := newChanRelayPCMSource(44100, 1)
	if err := remoteRelay.Start(source, "Test Song", ""); err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(remoteRelay.Stop)

	go func() {
		phase := 0.0
		for i := 0; i < 60; i++ {
			source.push(sineChunk(2048, &phase, 44100))
			time.Sleep(5 * time.Millisecond)
		}
	}()

	srv := httptest.NewServer(NewLANHTTPHandler(NewApp()))
	defer srv.Close()

	readSome := func() int {
		req, _ := http.NewRequest(http.MethodGet, srv.URL+"/v1/remote/relay", nil)
		req.Header.Set("Authorization", "Bearer "+token)
		resp, err := srv.Client().Do(req)
		if err != nil {
			t.Fatalf("GET /v1/remote/relay: %v", err)
		}
		defer resp.Body.Close()
		buf := make([]byte, 4096)
		total := 0
		// CI の共有 Linux ランナー（go test -race で全パッケージを並行実行して
		// おり、pkg/audio 側のデコード処理などと CPU を奪い合う）では、この
		// ffmpeg エンコードパイプラインへの供給ゴルーチンがスケジューリング
		// 遅延を受け、ローカル実行での数百ミリ秒よりずっと長くかかることが
		// 実測で確認できた（5秒では両方 0 バイトのまま打ち切られていた）。
		// アサーション自体（両クライアントとも受信できること）は変えず、
		// 待てば届くはずの遅延に対して猶予を広げる。
		deadline := time.Now().Add(20 * time.Second)
		for total < 8 && time.Now().Before(deadline) {
			n, err := resp.Body.Read(buf[total:])
			total += n
			if err != nil && err != io.EOF {
				break
			}
			if n == 0 {
				time.Sleep(10 * time.Millisecond)
			}
		}
		return total
	}

	done := make(chan int, 2)
	go func() { done <- readSome() }()
	go func() { done <- readSome() }()

	t1 := <-done
	t2 := <-done
	if t1 == 0 || t2 == 0 {
		t.Fatalf("expected both concurrent clients to receive bytes, got %d and %d", t1, t2)
	}
}

func TestSyncCapabilities_IncludesRelayOnlyInGUIMode(t *testing.T) {
	newTempRemoteStore(t)

	withServerMode(t, ModeGUI)
	handler := NewLANHTTPHandler(NewApp())
	req := httptest.NewRequest(http.MethodGet, "/v1/identity", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	var guiResp identityResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &guiResp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !containsString(guiResp.Capabilities, "remote.relay.v1") {
		t.Fatalf("expected remote.relay.v1 capability in GUI mode, got %v", guiResp.Capabilities)
	}

	withServerMode(t, ModeHeadless)
	rec2 := httptest.NewRecorder()
	handler.ServeHTTP(rec2, req)
	var headlessResp identityResponse
	if err := json.Unmarshal(rec2.Body.Bytes(), &headlessResp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if containsString(headlessResp.Capabilities, "remote.relay.v1") {
		t.Fatalf("did not expect remote.relay.v1 capability in headless mode, got %v", headlessResp.Capabilities)
	}
}

func containsString(list []string, target string) bool {
	for _, v := range list {
		if v == target {
			return true
		}
	}
	return false
}

func TestRemoteStateHandler_IncludesRelayBlockAdditively(t *testing.T) {
	newTempRemoteStore(t)
	withServerMode(t, ModeGUI)
	remoteRelay.Stop()
	token := ensureDeviceAuthToken("dev_test_state")

	handler := NewLANHTTPHandler(NewApp())
	req := httptest.NewRequest(http.MethodGet, "/v1/remote/state", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var status map[string]interface{}
	if err := json.Unmarshal(rec.Body.Bytes(), &status); err != nil {
		t.Fatalf("decode: %v", err)
	}
	relay, ok := status["relay"].(map[string]interface{})
	if !ok {
		t.Fatalf("expected relay block in state, got %#v", status)
	}
	if active, _ := relay["active"].(bool); active {
		t.Fatalf("expected relay.active=false when no source is running, got %#v", relay)
	}
}
