package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"
)

// handoffProbeBaseURLsFunc returns every loopback candidate the GUI probes at
// startup. It is a function seam so tests can provide httptest servers and
// deliberately slow TCP listeners without changing production candidates.
var handoffProbeBaseURLsFunc = defaultHandoffProbeBaseURLs

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

func defaultHandoffProbeBaseURLs() []string {
	ports := lanServerCandidatePorts()
	urls := make([]string, 0, len(ports))
	for _, port := range ports {
		urls = append(urls, fmt.Sprintf("http://127.0.0.1:%d", port))
	}
	return urls
}

type handoffProbeResult struct {
	baseURL string
	result  identityProbeResult
}

func probeHandoffTargets(baseURLs []string) []handoffProbeResult {
	results := make([]handoffProbeResult, len(baseURLs))
	var wg sync.WaitGroup
	for i, baseURL := range baseURLs {
		results[i].baseURL = baseURL
		wg.Add(1)
		go func(index int, target string) {
			defer wg.Done()
			results[index].result = probeIdentity(target)
		}(i, baseURL)
	}
	wg.Wait()
	return results
}

// performGUIHandoff is called from Startup, before StartLANServer binds. It
// probes every candidate port's /v1/identity concurrently to see who (if
// anyone) is already holding a candidate:
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
func performGUIHandoff() bool {
	results := probeHandoffTargets(handoffProbeBaseURLsFunc())
	var headlessBaseURL string
	for _, candidate := range results {
		if !candidate.result.reachable {
			continue
		}
		if rolesContain(candidate.result.roles, ModeGUI) {
			fmt.Println("[Handoff] another GUI instance already holds a LAN server port; not attempting takeover, starting without it")
			return false
		}
		if headlessBaseURL == "" && rolesContain(candidate.result.roles, ModeHeadless) {
			headlessBaseURL = candidate.baseURL
		}
	}
	if headlessBaseURL == "" {
		return false
	}

	fmt.Printf("[Handoff] resident headless instance detected at %s; taking over\n", headlessBaseURL)
	uid := strconv.Itoa(os.Getuid())
	if err := currentLaunchAgentRunner.Bootout(uid, launchAgentLabel); err != nil {
		fmt.Printf("[Handoff] launchctl bootout failed (%v); falling back to POST /v1/local/shutdown\n", err)
		requestLocalShutdown(headlessBaseURL)
	}
	waitForPortFree(headlessBaseURL)
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
