package server

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"math"
	"net/http"
	"os/exec"
	"strconv"
	"sync"
)

// remoteRelayCapability is advertised in /v1/identity's capabilities list,
// GUI mode only (see identityHandler). It tells TV/iPhone clients that
// GET /v1/remote/relay may be usable.
const remoteRelayCapability = "remote.relay.v1"

// relayAACBitrateKbps is fixed at 256kbps per markdown/appletv-servermode-plan.md
// §3-3 (AAC-LC first choice, hardware decode on tvOS/iOS). Unlike
// /v1/remote/file's bitrate query param, the relay is a single shared
// broadcast stream so there is no per-client bitrate negotiation.
const relayAACBitrateKbps = 256

// RelayPCMSource is a pull-based source of interleaved float32 PCM samples,
// implemented by whatever feeds the relay engine. ReadPCM may block until
// data is available; it returns ok=false once the source is exhausted or
// closed, at which point the engine tears itself down.
//
// This interface is the wiring seam mentioned in the Phase 3-3 task: tests
// inject a synthetic source (chanRelayPCMSource in app_remote_relay_test.go)
// so the engine, HTTP surface, and gating can be verified without Core Audio
// hardware. The real source — pkg/audio.ProcessTapCapture wrapping the
// process-tapped IFrame player audio — satisfies a very similar shape
// (ReadSamples/SampleRate/Channels) but is pull-based/non-blocking rather
// than blocking, and darwin-only (cgo). See progress/remote-relay.md for
// what remains to wire it in for real and why that wiring is left for
// on-machine verification.
type RelayPCMSource interface {
	ReadPCM(dst []float32) (n int, ok bool)
	SampleRate() int
	Channels() int
}

type relaySubscriber struct {
	ch chan []byte
}

// relayEngine fan-outs one AAC-LC ADTS encode of the active RelayPCMSource
// to any number of concurrent HTTP clients. Only one source can be active at
// a time (GUI mode plays one YouTube video at a time, per the plan's
// "broadcast" model — no per-client video/relay).
type relayEngine struct {
	mu sync.Mutex
	// generation counts every Start()/Stop() transition. Each Start() records
	// the generation it owns; the goroutine that calls cmd.Wait() for that
	// session's ffmpeg process only tears the engine down if its generation
	// is still current (see stopIfCurrent). This guards against a stale
	// session's teardown racing a newer one: Stop() does not (and, given
	// ffmpeg's process-exit latency, realistically cannot) wait for the
	// previous session's goroutines to fully exit before Start() launches the
	// next session, so without this guard a slow-to-exit previous ffmpeg
	// process can tear down a session that already replaced it. See
	// relay_ci_research/notes/ for the CI evidence that motivated this.
	generation int
	active     bool
	title      string
	thumbnail  string
	subs       map[int]*relaySubscriber
	nextSubID  int
	cancel     context.CancelFunc
	ffmpegPath func() (string, error)
}

func newRelayEngine() *relayEngine {
	return &relayEngine{
		subs:       map[int]*relaySubscriber{},
		ffmpegPath: locateFfmpeg,
	}
}

// remoteRelay is the process-wide relay engine backing GET /v1/remote/relay.
// Like currentServerMode, it is a package-level singleton because there is
// exactly one desktop playback pipeline per process.
var remoteRelay = newRelayEngine()

// Start begins encoding source to AAC-LC ADTS via ffmpeg and broadcasting it
// to subscribers. Any previously active source is stopped first. title and
// thumbnail feed the relay block of /v1/remote/state.
func (e *relayEngine) Start(source RelayPCMSource, title, thumbnail string) error {
	e.Stop()

	ffmpegPath, err := e.ffmpegPath()
	if err != nil {
		return fmt.Errorf("ffmpeg not found: %w", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(ctx, ffmpegPath,
		"-f", "f32le",
		"-ar", strconv.Itoa(source.SampleRate()),
		"-ac", strconv.Itoa(source.Channels()),
		// Raw PCM read from an open, unbounded stdin pipe: skip format
		// probing (there is nothing to probe — -f f32le already says what
		// it is) so ffmpeg starts decoding on the first bytes rather than
		// waiting to accumulate a default probe buffer.
		"-probesize", "32",
		"-analyzeduration", "0",
		"-i", "pipe:0",
		"-c:a", "aac",
		"-b:a", strconv.Itoa(relayAACBitrateKbps)+"k",
		// Without this, ffmpeg batches ADTS output in its internal avio
		// buffer and only writes to stdout when the buffer fills or the
		// process exits — fatal for a live broadcast, where "on exit" never
		// happens while playback continues. Confirmed empirically: a fifo
		// fed with the same cadence as the real tap produced zero output
		// bytes until stdin was closed, for both a plain file and a pipe
		// destination, until -probesize/-analyzeduration/-flush_packets
		// were added together (see progress/remote-relay.md).
		"-flush_packets", "1",
		"-f", "adts",
		"pipe:1",
	)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		cancel()
		return fmt.Errorf("ffmpeg stdin pipe: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		cancel()
		return fmt.Errorf("ffmpeg stdout pipe: %w", err)
	}
	if err := cmd.Start(); err != nil {
		cancel()
		return fmt.Errorf("ffmpeg start: %w", err)
	}

	e.mu.Lock()
	e.generation++
	gen := e.generation
	e.active = true
	e.title = title
	e.thumbnail = thumbnail
	e.cancel = cancel
	e.mu.Unlock()

	go e.pumpPCM(source, stdin)
	go e.pumpADTS(stdout)
	go func() {
		_ = cmd.Wait()
		e.stopIfCurrent(gen)
	}()

	return nil
}

// stopIfCurrent tears the engine down (as Stop does) only if gen is still
// the generation that is currently active. It is the teardown path for a
// session's own cmd.Wait() goroutine: if a newer Start() has already
// replaced this session by the time ffmpeg exits — plausible on a loaded
// runner, where process-exit and pipe-EOF latency after Stop()'s
// cancel() can outlast the next Start() — tearing down unconditionally
// would kill the new session's subscribers instead of the old, exited one.
// Explicit callers (t.Cleanup(remoteRelay.Stop), Start()'s own leading
// e.Stop()) go through Stop() directly and always tear down, bumping the
// generation so any still-pending stopIfCurrent(oldGen) becomes a no-op.
func (e *relayEngine) stopIfCurrent(gen int) {
	e.mu.Lock()
	if gen != e.generation {
		e.mu.Unlock()
		return
	}
	e.mu.Unlock()
	e.Stop()
}

// pumpPCM reads interleaved float32 frames from source and writes them as
// little-endian f32le bytes to ffmpeg's stdin until the source is exhausted
// or stdin is closed (engine stopped).
func (e *relayEngine) pumpPCM(source RelayPCMSource, stdin io.WriteCloser) {
	defer stdin.Close()
	samples := make([]float32, 4096)
	bytes := make([]byte, len(samples)*4)
	for {
		n, ok := source.ReadPCM(samples)
		if !ok {
			return
		}
		if n == 0 {
			continue
		}
		for i := 0; i < n; i++ {
			binary.LittleEndian.PutUint32(bytes[i*4:], math.Float32bits(samples[i]))
		}
		if _, err := stdin.Write(bytes[:n*4]); err != nil {
			return
		}
	}
}

// pumpADTS reads encoded ADTS bytes from ffmpeg's stdout and fans each chunk
// out to every current subscriber.
func (e *relayEngine) pumpADTS(stdout io.ReadCloser) {
	defer stdout.Close()
	buf := make([]byte, 4096)
	for {
		n, err := stdout.Read(buf)
		if n > 0 {
			chunk := make([]byte, n)
			copy(chunk, buf[:n])
			e.broadcast(chunk)
		}
		if err != nil {
			return
		}
	}
}

// broadcast sends chunk to every subscriber's channel without blocking; a
// subscriber too slow to keep up drops the chunk rather than stalling the
// other clients or the encode pipeline.
func (e *relayEngine) broadcast(chunk []byte) {
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, sub := range e.subs {
		select {
		case sub.ch <- chunk:
		default:
		}
	}
}

// Stop tears down the active encode (if any) and closes every subscriber's
// channel, ending their HTTP responses. Safe to call when nothing is active.
func (e *relayEngine) Stop() {
	e.mu.Lock()
	// Bump unconditionally (even when nothing is active) so that any
	// stopIfCurrent(gen) still in flight from a previous session's cmd.Wait()
	// goroutine is guaranteed to see a mismatch and no-op, regardless of
	// whether this Stop() call itself has anything to tear down.
	e.generation++
	if !e.active {
		e.mu.Unlock()
		return
	}
	e.active = false
	e.title = ""
	e.thumbnail = ""
	cancel := e.cancel
	e.cancel = nil
	subs := e.subs
	e.subs = map[int]*relaySubscriber{}
	e.mu.Unlock()

	if cancel != nil {
		cancel()
	}
	for _, sub := range subs {
		close(sub.ch)
	}
}

// Subscribe registers a new client and returns its delivery channel plus an
// unsubscribe func the caller must invoke exactly once (e.g. via defer) when
// the client disconnects. Late joiners only see chunks broadcast after
// Subscribe returns — there is no backlog replay, matching the plan's "start
// at the live edge" requirement.
func (e *relayEngine) Subscribe() (chan []byte, func()) {
	e.mu.Lock()
	defer e.mu.Unlock()
	id := e.nextSubID
	e.nextSubID++
	ch := make(chan []byte, 32)
	e.subs[id] = &relaySubscriber{ch: ch}
	return ch, func() { e.unsubscribe(id) }
}

func (e *relayEngine) unsubscribe(id int) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if sub, ok := e.subs[id]; ok {
		delete(e.subs, id)
		close(sub.ch)
	}
}

// State returns whether a relay source is currently active and its metadata,
// for /v1/remote/state's relay block.
func (e *relayEngine) State() (active bool, title, thumbnail string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.active, e.title, e.thumbnail
}

// remoteRelayHandler serves GET /v1/remote/relay: chunked, authenticated
// AAC-LC ADTS audio of whatever YouTube video is currently playing through
// the GUI's official embed. Exists only in GUI mode (404 in headless, same
// pattern as /v1/local/shutdown's mode gate) and only while a source is
// active (409 otherwise).
func remoteRelayHandler(w http.ResponseWriter, r *http.Request) {
	if CurrentServerMode() != ModeGUI {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodGet {
		writeAPIError(w, "GET only", http.StatusMethodNotAllowed)
		return
	}
	active, _, _ := remoteRelay.State()
	if !active {
		writeAPIError(w, "no active relay source", http.StatusConflict)
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeAPIError(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}

	ch, unsubscribe := remoteRelay.Subscribe()
	defer unsubscribe()

	w.Header().Set("Content-Type", "audio/aac")
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	for {
		select {
		case chunk, ok := <-ch:
			if !ok {
				return
			}
			if _, err := w.Write(chunk); err != nil {
				return
			}
			flusher.Flush()
		case <-r.Context().Done():
			return
		}
	}
}
