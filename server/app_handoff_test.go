package server

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func identityStub(t *testing.T, roles []string) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/identity", func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(map[string]interface{}{"roles": roles})
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func TestPerformGUIHandoff_NoResidentInstance_ReturnsFalse(t *testing.T) {
	stub := &stubLaunchAgentRunner{}
	withStubLaunchAgentRunner(t, stub)
	withHandoffProbeTargets(t, []string{"http://127.0.0.1:1"})

	// Nothing listening at this base URL at all.
	tookOver := performGUIHandoff()
	if tookOver {
		t.Fatalf("expected no takeover when nothing is reachable")
	}
	if len(stub.bootoutCalls) != 0 {
		t.Fatalf("expected no Bootout call, got %v", stub.bootoutCalls)
	}
}

func TestPerformGUIHandoff_ResidentHeadless_BootsOutViaLaunchctl(t *testing.T) {
	stub := &stubLaunchAgentRunner{}
	withStubLaunchAgentRunner(t, stub)

	callCount := 0
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/identity", func(w http.ResponseWriter, r *http.Request) {
		callCount++
		if callCount == 1 {
			json.NewEncoder(w).Encode(map[string]interface{}{"roles": []string{"headless"}})
			return
		}
		// Simulate the resident instance having gone away after bootout.
		http.Error(w, "connection refused", http.StatusServiceUnavailable)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	withHandoffProbeTargets(t, []string{srv.URL})

	tookOver := performGUIHandoff()
	if !tookOver {
		t.Fatalf("expected takeover to report true for a resident headless instance")
	}
	if len(stub.bootoutCalls) != 1 || stub.bootoutCalls[0] != launchAgentLabel {
		t.Fatalf("expected exactly one Bootout call with label %s, got %v", launchAgentLabel, stub.bootoutCalls)
	}
}

func TestPerformGUIHandoff_LaunchctlFails_FallsBackToLocalShutdown(t *testing.T) {
	stub := &stubLaunchAgentRunner{bootoutErr: errBootoutFailedForTest}
	withStubLaunchAgentRunner(t, stub)

	shutdownCalled := false
	callCount := 0
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/identity", func(w http.ResponseWriter, r *http.Request) {
		callCount++
		if callCount == 1 {
			json.NewEncoder(w).Encode(map[string]interface{}{"roles": []string{"headless"}})
			return
		}
		http.Error(w, "connection refused", http.StatusServiceUnavailable)
	})
	mux.HandleFunc("/v1/local/shutdown", func(w http.ResponseWriter, r *http.Request) {
		shutdownCalled = true
		w.WriteHeader(http.StatusOK)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	withHandoffProbeTargets(t, []string{srv.URL})

	tookOver := performGUIHandoff()
	if !tookOver {
		t.Fatalf("expected takeover to report true even via the fallback path")
	}
	if !shutdownCalled {
		t.Fatalf("expected /v1/local/shutdown fallback to be called when launchctl bootout fails")
	}
}

func TestPerformGUIHandoff_AnotherGUIRunning_DoesNotTakeOver(t *testing.T) {
	stub := &stubLaunchAgentRunner{}
	withStubLaunchAgentRunner(t, stub)

	srv := identityStub(t, []string{"gui"})
	withHandoffProbeTargets(t, []string{srv.URL})

	tookOver := performGUIHandoff()
	if tookOver {
		t.Fatalf("must not attempt takeover when another GUI instance holds the port")
	}
	if len(stub.bootoutCalls) != 0 {
		t.Fatalf("expected no Bootout call when another GUI instance is running, got %v", stub.bootoutCalls)
	}
}

func TestPerformGUIHandoff_FindsHeadlessOnNonPreferredCandidateAlongsideSlowListener(t *testing.T) {
	stub := &stubLaunchAgentRunner{}
	withStubLaunchAgentRunner(t, stub)

	slowListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen slow probe: %v", err)
	}
	defer slowListener.Close()
	var acceptWG sync.WaitGroup
	acceptWG.Add(1)
	go func() {
		defer acceptWG.Done()
		for {
			conn, acceptErr := slowListener.Accept()
			if acceptErr != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				buffer := make([]byte, 1)
				_, _ = conn.Read(buffer)
			}(conn)
		}
	}()

	callCount := 0
	var callMu sync.Mutex
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/identity", func(w http.ResponseWriter, r *http.Request) {
		callMu.Lock()
		callCount++
		current := callCount
		callMu.Unlock()
		if current == 1 {
			json.NewEncoder(w).Encode(map[string]interface{}{"roles": []string{"headless"}})
			return
		}
		http.Error(w, "gone", http.StatusServiceUnavailable)
	})
	resident := httptest.NewServer(mux)
	defer resident.Close()

	withHandoffProbeTargets(t, []string{resident.URL, "http://" + slowListener.Addr().String()})
	started := time.Now()
	tookOver := performGUIHandoff()
	elapsed := time.Since(started)
	if !tookOver {
		t.Fatal("expected takeover from non-preferred candidate")
	}
	if elapsed > handoffHTTPTimeout+700*time.Millisecond {
		t.Fatalf("concurrent probes took too long: %v", elapsed)
	}
	slowListener.Close()
	acceptWG.Wait()
}

func withHandoffProbeTargets(t *testing.T, targets []string) {
	t.Helper()
	old := handoffProbeBaseURLsFunc
	handoffProbeBaseURLsFunc = func() []string { return append([]string(nil), targets...) }
	t.Cleanup(func() { handoffProbeBaseURLsFunc = old })
}

// errBootoutFailedForTest is a sentinel error used only by tests to simulate
// a launchctl bootout failure.
var errBootoutFailedForTest = &stubError{"simulated launchctl bootout failure"}

type stubError struct{ msg string }

func (e *stubError) Error() string { return e.msg }

func TestAppShutdown_RestoresResidentAgentIfBootedOut(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	stub := &stubLaunchAgentRunner{}
	withStubLaunchAgentRunner(t, stub)

	a := NewApp()
	a.bootedOutResidentAgent = true
	a.Shutdown(nil)

	if len(stub.bootstrapCalls) != 1 {
		t.Fatalf("expected Shutdown to re-bootstrap the resident agent, got %v", stub.bootstrapCalls)
	}
}

func TestAppShutdown_DoesNotRestoreAgentWhenNotBootedOut(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	stub := &stubLaunchAgentRunner{}
	withStubLaunchAgentRunner(t, stub)

	a := NewApp()
	a.Shutdown(nil)

	if len(stub.bootstrapCalls) != 0 {
		t.Fatalf("expected no Bootstrap call when we never booted out the resident agent, got %v", stub.bootstrapCalls)
	}
}
