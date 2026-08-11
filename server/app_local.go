package server

import (
	"net"
	"net/http"
)

// localShutdownPath is the loopback-only headless shutdown route. It is
// registered unconditionally (see registerLocalRoutes) but only answers
// while the process is running in headless mode and only for requests whose
// remote address resolves to loopback; every other caller sees a plain 404,
// as if the route did not exist. This is groundwork for the launchd
// GUI-handoff fallback (Phase 0-3) — launchctl is the primary stop
// mechanism, this endpoint is the fallback when launchctl is unavailable.
const localShutdownPath = "/v1/local/shutdown"

// headlessShutdownTrigger is invoked by localShutdownHandler once a valid
// loopback shutdown request is accepted. runHeadlessServe overrides it at
// startup to signal the graceful-shutdown path; it defaults to a no-op so
// GUI mode (which never reaches this far) and tests stay safe.
var headlessShutdownTrigger = func() {}

// setHeadlessShutdownTrigger overrides headlessShutdownTrigger and returns a
// func that restores the previous value. RunHeadlessServe uses this to wire
// the endpoint to its own shutdown signal; tests use it to observe whether
// the trigger fired without actually tearing anything down.
func setHeadlessShutdownTrigger(fn func()) func() {
	previous := headlessShutdownTrigger
	headlessShutdownTrigger = fn
	return func() { headlessShutdownTrigger = previous }
}

// setHeadlessShutdownTriggerForTest is an alias kept for test readability.
func setHeadlessShutdownTriggerForTest(fn func()) func() {
	return setHeadlessShutdownTrigger(fn)
}

func registerLocalRoutes(mux *http.ServeMux) {
	mux.HandleFunc(localShutdownPath, localShutdownHandler)
}

func localShutdownHandler(w http.ResponseWriter, r *http.Request) {
	if CurrentServerMode() != ModeHeadless {
		http.NotFound(w, r)
		return
	}
	if r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	if !remoteAddrIsLoopback(r.RemoteAddr) {
		http.NotFound(w, r)
		return
	}
	w.WriteHeader(http.StatusOK)
	headlessShutdownTrigger()
}

// remoteAddrIsLoopback reports whether an http.Request.RemoteAddr
// (host:port form) resolves to a loopback address (127.0.0.1/::1).
func remoteAddrIsLoopback(remoteAddr string) bool {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		host = remoteAddr
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	return ip.IsLoopback()
}
