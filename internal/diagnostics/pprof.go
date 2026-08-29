// Package diagnostics wires up opt-in, developer-only instrumentation for the
// UX-Music Go process. It intentionally has no effect unless an environment
// variable explicitly enables it, and is not part of any user-facing feature.
package diagnostics

import (
	"log"
	"net"
	"net/http"
	// Registers the /debug/pprof/* handlers on http.DefaultServeMux as a side
	// effect of being imported.
	_ "net/http/pprof"
)

// pprofEnvVar is the environment variable that opts into the diagnostics-only
// pprof HTTP server. It is unset by default, so pprof never listens unless a
// developer explicitly sets it while investigating memory/CPU behaviour.
const pprofEnvVar = "UXMUSIC_PPROF"

// ResolvePprofAddr validates the value of UXMUSIC_PPROF and returns the
// address to listen on. It only accepts loopback addresses ("127.0.0.1:PORT",
// "localhost:PORT", or "[::1]:PORT") so the profiling endpoint can never be
// exposed on a LAN-reachable interface; anything else (including the empty
// string, a bare port, or a wildcard/non-loopback host) is refused.
func ResolvePprofAddr(env string) (string, bool) {
	if env == "" {
		return "", false
	}

	host, _, err := net.SplitHostPort(env)
	if err != nil {
		return "", false
	}

	if host != "127.0.0.1" && host != "localhost" && host != "::1" {
		return "", false
	}

	return env, true
}

// StartPprofIfEnabled starts the net/http/pprof server in a background
// goroutine when UXMUSIC_PPROF is set to a valid loopback address. It is
// diagnostics-only: call it once from a shared startup path (both the GUI and
// `--serve` entry points go through main(), so calling it there covers both).
// A failed listen is logged, not fatal — this must never affect normal
// operation.
func StartPprofIfEnabled(env string) {
	addr, ok := ResolvePprofAddr(env)
	if !ok {
		if env != "" {
			log.Printf("[diagnostics] %s=%q is not a loopback address; pprof server not started", pprofEnvVar, env)
		}
		return
	}

	log.Printf("[diagnostics] starting pprof server on http://%s/debug/pprof/ (diagnostics only)", addr)
	go func() {
		if err := http.ListenAndServe(addr, nil); err != nil {
			log.Printf("[diagnostics] pprof server stopped: %v", err)
		}
	}()
}
