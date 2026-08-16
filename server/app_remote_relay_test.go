package server

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os/exec"
	"strings"
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

// TestRelayEngine_StaleGenerationStopIsNoOp is a white-box regression test
// for the reentrancy hazard described in
// relay_ci_research/notes/stale-cmd-wait-teardown.md: Start()'s trailing
// `go func(){ cmd.Wait(); e.Stop() }()` used to tear the engine down
// unconditionally, with no way to tell "my session" apart from "whichever
// session happens to be active when I finally get scheduled". A slow-to-exit
// previous ffmpeg process could therefore kill a session that had already
// replaced it. It does not spawn a real ffmpeg process — that would make the
// stale-goroutine race itself nondeterministic to test — instead it drives
// the generation guard (stopIfCurrent) directly against manually-set engine
// state, which is exactly the mechanism the real cmd.Wait() goroutine
// exercises.
func TestRelayEngine_StaleGenerationStopIsNoOp(t *testing.T) {
	e := newRelayEngine()

	// Simulate session 1 having started (generation 1) and already having
	// been superseded by session 2 (generation 2, the "current" one).
	e.mu.Lock()
	e.generation = 2
	e.active = true
	ch := make(chan []byte, 1)
	e.subs[0] = &relaySubscriber{ch: ch}
	e.mu.Unlock()

	// Session 1's cmd.Wait() goroutine finally returns and calls
	// stopIfCurrent(1). It must be a no-op: session 2 is still current.
	e.stopIfCurrent(1)

	active, _, _ := e.State()
	if !active {
		t.Fatalf("stopIfCurrent(stale generation) deactivated the engine, want the current session left running")
	}
	select {
	case _, ok := <-ch:
		if !ok {
			t.Fatalf("stopIfCurrent(stale generation) closed the current session's subscriber channel")
		}
	default:
	}

	// Session 2's own cmd.Wait() goroutine returns and calls
	// stopIfCurrent(2). This must actually tear the engine down.
	e.stopIfCurrent(2)

	active, _, _ = e.State()
	if active {
		t.Fatalf("stopIfCurrent(current generation) left the engine active, want it torn down")
	}
	if _, ok := <-ch; ok {
		t.Fatalf("stopIfCurrent(current generation) left the subscriber channel open, want it closed")
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
	// relay_ci_research/notes/ で GitHub Actions 固有の失敗を計測中。
	// 診断のため一時的に GITHUB_ACTIONS スキップを外し、relayEngine.debugf
	// 経由で ffmpeg stderr・バイト数・購読者数を t.Logf に出している。
	requireFFmpegForTest(t)
	newTempRemoteStore(t)
	withServerMode(t, ModeGUI)
	token := ensureDeviceAuthToken("dev_test_multi")

	if path, err := exec.LookPath("ffmpeg"); err == nil {
		if out, verErr := exec.Command(path, "-version").Output(); verErr == nil {
			firstLine := string(out)
			if idx := strings.IndexByte(firstLine, '\n'); idx >= 0 {
				firstLine = firstLine[:idx]
			}
			t.Logf("[diag] ffmpeg path=%s version=%q", path, firstLine)
		} else {
			t.Logf("[diag] ffmpeg -version failed: %v", verErr)
		}
	} else {
		t.Logf("[diag] exec.LookPath(ffmpeg) failed: %v", err)
	}

	remoteRelay.setDebugf(t.Logf)
	t.Cleanup(func() { remoteRelay.setDebugf(nil) })

	source := newChanRelayPCMSource(44100, 1)
	if err := remoteRelay.Start(source, "Test Song", ""); err != nil {
		t.Fatalf("Start: %v", err)
	}
	t.Cleanup(remoteRelay.Stop)

	// 元々は 60 回（実時間 300ms）しか PCM を送っていなかった。
	// Subscribe は「呼び出し後に broadcast された分しか受け取れず、
	// バックログの再生は無い」設計（relayEngine.Subscribe のコメント参照）
	// なので、httptest.NewServer の起動や2クライアント分の HTTP
	// ハンドシェイクが CI の混雑したランナーでこの 300ms の生配信ウィンドウ
	// より遅く終わると、購読が完了した時点でもう新しいチャンクが一切
	// 来ず、読み取り側のデッドラインをいくら伸ばしても 0 バイトのまま
	// 打ち切られる（実際に CI で確認済みの症状と一致する）。本番の
	// バックログ非対応という仕様自体は変えず、テストの生配信ウィンドウを
	// 5秒に広げて購読の遅延に対する猶予を確保する。
	stopPush := make(chan struct{})
	t.Cleanup(func() { close(stopPush) })
	go func() {
		phase := 0.0
		for i := 0; i < 1000; i++ {
			select {
			case <-stopPush:
				return
			case source.ch <- sineChunk(2048, &phase, 44100):
			}
			select {
			case <-stopPush:
				return
			case <-time.After(5 * time.Millisecond):
			}
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
