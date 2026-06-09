package uxsync

import (
	"testing"
	"time"
)

func TestPairingCode_isStableSixDigitCode(t *testing.T) {
	code := PairingCode([]byte("shared pairing secret"))

	if code != PairingCode([]byte("shared pairing secret")) {
		t.Fatal("expected pairing code to be stable for the same secret")
	}
	if len(code) != 6 {
		t.Fatalf("expected six digit code, got %q", code)
	}
	for _, r := range code {
		if r < '0' || r > '9' {
			t.Fatalf("expected digits only, got %q", code)
		}
	}
}

func TestPairingSession_expiry(t *testing.T) {
	now := time.Date(2026, 6, 8, 12, 0, 0, 0, time.UTC)
	session := NewPairingSession("dev_air", []byte("shared pairing secret"), now, 2*time.Minute)

	if session.Code != PairingCode([]byte("shared pairing secret")) {
		t.Fatalf("session code did not match derived code: %q", session.Code)
	}
	if session.IsExpired(now.Add(time.Minute)) {
		t.Fatal("session expired too early")
	}
	if !session.IsExpired(now.Add(3 * time.Minute)) {
		t.Fatal("session should expire after ttl")
	}
}
