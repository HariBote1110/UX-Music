package server

import (
	"testing"
	"time"
)

func TestSyncDiscoveryTimeout_clampsUserInput(t *testing.T) {
	if got := syncDiscoveryTimeout(0); got != 2*time.Second {
		t.Fatalf("expected default timeout, got %s", got)
	}
	if got := syncDiscoveryTimeout(250); got != 250*time.Millisecond {
		t.Fatalf("expected 250ms timeout, got %s", got)
	}
	if got := syncDiscoveryTimeout(60000); got != 10*time.Second {
		t.Fatalf("expected max timeout, got %s", got)
	}
}
