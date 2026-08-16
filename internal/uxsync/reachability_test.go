package uxsync

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sync"
	"testing"
)

// handlerObserver は httptest ハンドラーゴルーチンからの観測結果を溜める。
// ハンドラー内で t.Fatalf を呼ぶと FailNow がテスト外ゴルーチンで走り、応答を
// 返さないままハンドラーが終了して無関係な失敗に化けるため、記録だけ行い
// テストゴルーチン側で assertNoErrors する。
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

func TestMDNSPeerCandidateBaseURLs_includesAllHostsInOrder(t *testing.T) {
	peer := MDNSPeer{
		Host:  "192.168.1.182",
		Hosts: []string{"192.168.1.182", "192.168.0.226"},
		Port:  8765,
	}

	got := peer.CandidateBaseURLs()

	if len(got) != 2 {
		t.Fatalf("expected two candidates, got %#v", got)
	}
	if got[0] != "http://192.168.1.182:8765" || got[1] != "http://192.168.0.226:8765" {
		t.Fatalf("unexpected candidates: %#v", got)
	}
}

func TestResolveReachablePeer_selectsFirstResponsiveCandidate(t *testing.T) {
	observer := &handlerObserver{}
	okServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/identity" {
			observer.errorf("unexpected probe path: %s", r.URL.Path)
			http.Error(w, "unexpected probe path", http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"role":"ux-music-sync"}`))
	}))
	defer okServer.Close()

	peer := MDNSPeer{
		Host:  "127.0.0.1",
		Hosts: []string{"127.0.0.1"},
		Port:  1,
	}
	peer.Hosts = append(peer.Hosts, hostPortFromURL(t, okServer.URL))

	resolved, err := ResolveReachablePeer(peer, nil)
	observer.assertNoErrors(t)
	if err != nil {
		t.Fatalf("expected reachable peer: %v", err)
	}
	if resolved.ReachableBaseURL != okServer.URL {
		t.Fatalf("expected %s, got %s", okServer.URL, resolved.ReachableBaseURL)
	}
}

func hostPortFromURL(t *testing.T, raw string) string {
	t.Helper()
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("parse test server URL: %v", err)
	}
	return u.Host
}
