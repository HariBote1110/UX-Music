package server

import (
	"errors"
	"reflect"
	"sync"
	"testing"
	"time"
	"ux-music-sidecar/pkg/mtp"
)

type fakeMTPOps struct {
	mu                                        sync.Mutex
	initialiseCalls, fetchCalls, disposeCalls int
	failures                                  int
	present                                   bool
	storageErr                                error
}

func (f *fakeMTPOps) Initialize() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.initialiseCalls++
	if !f.present || f.initialiseCalls <= f.failures {
		return errors.New("unavailable")
	}
	return nil
}
func (f *fakeMTPOps) FetchDeviceInfo() (map[string]interface{}, error) {
	return map[string]interface{}{"mtpDeviceInfo": map[string]interface{}{"Model": "Test phone"}}, nil
}
func (f *fakeMTPOps) FetchStorages() ([]mtp.Storage, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.fetchCalls++
	if f.storageErr != nil {
		return nil, f.storageErr
	}
	return []mtp.Storage{{ID: 7}}, nil
}
func (f *fakeMTPOps) Dispose() error { f.mu.Lock(); defer f.mu.Unlock(); f.disposeCalls++; return nil }
func (f *fakeMTPOps) counts() (int, int, int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.initialiseCalls, f.fetchCalls, f.disposeCalls
}

type monitorHarness struct {
	ops         *fakeMTPOps
	events      chan bool
	stop        chan struct{}
	done        chan struct{}
	mu          sync.Mutex
	connected   bool
	payloads    []interface{}
	disconnects int
}

func newMonitorHarness(ops *fakeMTPOps) *monitorHarness {
	h := &monitorHarness{ops: ops, events: make(chan bool, 16), stop: make(chan struct{}), done: make(chan struct{})}
	m := mtpHotplugMonitor{ops: ops, events: h.events, settle: 15 * time.Millisecond, retryDelays: []time.Duration{15 * time.Millisecond, 15 * time.Millisecond}, isConnected: func() bool { h.mu.Lock(); defer h.mu.Unlock(); return h.connected }, onConnected: func(p interface{}) {
		h.mu.Lock()
		defer h.mu.Unlock()
		h.connected = true
		h.payloads = append(h.payloads, p)
	}, onDisconnected: func() { h.mu.Lock(); defer h.mu.Unlock(); h.connected = false; h.disconnects++ }}
	go func() { defer close(h.done); m.run(h.stop) }()
	return h
}
func (h *monitorHarness) close() { close(h.stop); <-h.done }
func (h *monitorHarness) state() (bool, int, int) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.connected, len(h.payloads), h.disconnects
}
func awaitMTP(t *testing.T, fn func() bool) {
	t.Helper()
	deadline := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(deadline) {
		if fn() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("monitor did not reach expected state")
}
func TestMTPHotplugInitialAttemptAndPayload(t *testing.T) {
	ops := &fakeMTPOps{present: true}
	h := newMonitorHarness(ops)
	defer h.close()
	awaitMTP(t, func() bool { c, n, _ := h.state(); return c && n == 1 })
	h.mu.Lock()
	got := h.payloads[0]
	h.mu.Unlock()
	want := map[string]interface{}{"device": map[string]interface{}{"name": "Test phone", "mtpDeviceInfo": map[string]interface{}{"mtpDeviceInfo": map[string]interface{}{"Model": "Test phone"}}}, "storages": []map[string]interface{}{{"id": uint32(7), "free": int64(0), "total": int64(0), "description": ""}}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("payload = %#v, want %#v", got, want)
	}
	var pollingPayload interface{}
	if !completeMTPConnection(&fakeMTPOps{present: true}, func(payload interface{}) { pollingPayload = payload }) {
		t.Fatal("polling connection completion failed")
	}
	if !reflect.DeepEqual(got, pollingPayload) {
		t.Fatalf("hotplug payload = %#v, polling payload = %#v", got, pollingPayload)
	}
	time.Sleep(60 * time.Millisecond)
	calls, _, _ := ops.counts()
	if calls != 1 {
		t.Fatalf("unexpected periodic initialisation: %d calls", calls)
	}
}
func TestMTPHotplugArrivalBurstAndRetries(t *testing.T) {
	for _, tc := range []struct {
		name           string
		failures, want int
		connect        bool
	}{{"burst", 0, 2, true}, {"retry success", 2, 3, true}, {"give up", 10, 4, false}} {
		t.Run(tc.name, func(t *testing.T) {
			ops := &fakeMTPOps{failures: tc.failures}
			h := newMonitorHarness(ops)
			defer h.close()
			awaitMTP(t, func() bool { n, _, _ := ops.counts(); return n == 1 })
			ops.mu.Lock()
			ops.present = true
			ops.mu.Unlock()
			for i := 0; i < 5; i++ {
				h.events <- true
			}
			awaitMTP(t, func() bool { n, _, _ := ops.counts(); return n >= tc.want })
			time.Sleep(75 * time.Millisecond)
			n, _, _ := ops.counts()
			if n != tc.want {
				t.Fatalf("initialise calls = %d, want %d", n, tc.want)
			}
			connected, _, _ := h.state()
			if connected != tc.connect {
				t.Fatalf("connected = %v", connected)
			}
			if !tc.connect {
				h.events <- true
				awaitMTP(t, func() bool { n, _, _ := ops.counts(); return n == 5 })
			}
		})
	}
}
func TestMTPHotplugLeftChecksDevice(t *testing.T) {
	for _, failed := range []bool{false, true} {
		t.Run(map[bool]string{false: "other device", true: "MTP device"}[failed], func(t *testing.T) {
			ops := &fakeMTPOps{present: true}
			h := newMonitorHarness(ops)
			defer h.close()
			awaitMTP(t, func() bool { c, _, _ := h.state(); return c })
			if failed {
				ops.mu.Lock()
				ops.storageErr = errors.New("gone")
				ops.mu.Unlock()
			}
			h.events <- false
			awaitMTP(t, func() bool { _, n, _ := ops.counts(); return n == 2 })
			connected, _, disconnects := h.state()
			_, _, disposed := ops.counts()
			if connected == failed || disconnects != map[bool]int{false: 0, true: 1}[failed] || disposed != disconnects {
				t.Fatalf("connected=%v disconnects=%d disposed=%d", connected, disconnects, disposed)
			}
		})
	}
}
func TestMTPHotplugLeftCancelsAndStop(t *testing.T) {
	ops := &fakeMTPOps{}
	h := newMonitorHarness(ops)
	awaitMTP(t, func() bool { n, _, _ := ops.counts(); return n == 1 })
	h.events <- true
	h.events <- false
	time.Sleep(40 * time.Millisecond)
	n, _, _ := ops.counts()
	if n != 1 {
		t.Fatalf("pending attempt ran: %d", n)
	}
	h.events <- true
	h.close()
	time.Sleep(40 * time.Millisecond)
	n, _, _ = ops.counts()
	if n != 1 {
		t.Fatalf("attempt ran after stop: %d", n)
	}
}
