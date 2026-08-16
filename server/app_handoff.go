package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"time"
)

// handoffProbeBaseURL is the loopback base URL the GUI probes at startup to
// detect a resident `--serve` instance already holding port 8765. It is a
// package variable (rather than a literal baked into performGUIHandoff)
// purely so production code can keep using the real port while every test
// points it at an httptest server instead.
var handoffProbeBaseURL = "http://127.0.0.1:" + lanServerPort

const (
	handoffHTTPTimeout      = 1500 * time.Millisecond
	handoffPortPollTimeout  = 10 * time.Second
	handoffPortPollInterval = 100 * time.Millisecond
)

// identityProbeResult is the outcome of probing GET /v1/identity.
type identityProbeResult struct {
	reachable bool
	roles     []string
}

// probeIdentity queries baseURL's /v1/identity and reports whether it
// answered and what roles it reported. Any failure (connection refused,
// timeout, non-200, malformed body) is treated as "not reachable" — from the
// caller's point of view an unreachable port and a port nothing is
// listening on are the same thing (nobody to hand off to/from).
func probeIdentity(baseURL string) identityProbeResult {
	client := &http.Client{Timeout: handoffHTTPTimeout}
	resp, err := client.Get(baseURL + "/v1/identity")
	if err != nil {
		return identityProbeResult{}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return identityProbeResult{}
	}
	var body struct {
		Roles []string `json:"roles"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return identityProbeResult{}
	}
	return identityProbeResult{reachable: true, roles: body.Roles}
}

func rolesContain(roles []string, target string) bool {
	for _, r := range roles {
		if r == target {
			return true
		}
	}
	return false
}

// performGUIHandoff is called from Startup, before StartLANServer binds
// port 8765. It probes baseURL's /v1/identity to see who (if anyone) is
// already holding the port:
//   - Nobody reachable: nothing to do, GUI proceeds to bind normally.
//   - A resident headless (`--serve`) instance: take over — bootout via
//     launchctl (through currentLaunchAgentRunner), falling back to
//     POST /v1/local/shutdown if the bootout call itself fails (e.g. the
//     agent was never installed via --install-agent), then poll until the
//     port is free. Returns true so Startup can remember to bootstrap the
//     agent again on Shutdown.
//   - Another GUI instance: do NOT take over (there is nothing to hand off
//     — a second GUI has no business evicting the first one). Log a
//     warning and return false; StartLANServer's own bind failure handling
//     (ListenAndServe's error is logged, not fatal — see app_remote.go)
//     means the caller ends up running without a LAN server, which is the
//     intended degraded state.
func performGUIHandoff(baseURL string) bool {
	result := probeIdentity(baseURL)
	if !result.reachable {
		return false
	}
	if rolesContain(result.roles, ModeGUI) {
		fmt.Println("[Handoff] another GUI instance already holds the LAN server port; not attempting takeover, starting without it")
		return false
	}
	if !rolesContain(result.roles, ModeHeadless) {
		return false
	}

	fmt.Println("[Handoff] resident headless instance detected; taking over")
	uid := strconv.Itoa(os.Getuid())
	if err := currentLaunchAgentRunner.Bootout(uid, launchAgentLabel); err != nil {
		fmt.Printf("[Handoff] launchctl bootout failed (%v); falling back to POST /v1/local/shutdown\n", err)
		requestLocalShutdown(baseURL)
	}
	waitForPortFree(baseURL)
	return true
}

// requestLocalShutdown POSTs the loopback-only fallback shutdown endpoint
// (server/app_local.go). Used only when launchctl bootout fails, e.g.
// because the resident instance was started manually rather than via
// --install-agent.
func requestLocalShutdown(baseURL string) {
	client := &http.Client{Timeout: handoffHTTPTimeout}
	req, err := http.NewRequest(http.MethodPost, baseURL+"/v1/local/shutdown", nil)
	if err != nil {
		return
	}
	resp, err := client.Do(req)
	if err != nil {
		return
	}
	resp.Body.Close()
}

// waitForPortFree polls baseURL's /v1/identity until it stops answering or
// handoffPortPollTimeout elapses, whichever comes first. Either outcome lets
// Startup proceed to bind: if the timeout is hit, StartLANServer's own bind
// failure handling takes over (logged, non-fatal).
func waitForPortFree(baseURL string) {
	deadline := time.Now().Add(handoffPortPollTimeout)
	for time.Now().Before(deadline) {
		if !probeIdentity(baseURL).reachable {
			return
		}
		time.Sleep(handoffPortPollInterval)
	}
}
