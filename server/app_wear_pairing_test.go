package server

import (
	"net/url"
	"testing"
)

func TestWearPairingURLFromParts(t *testing.T) {
	got := wearPairingURLFromParts("192.168.0.5", "8765")
	want := "uxmusic://pair?host=192.168.0.5&port=8765"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestWearPairingURLFromParts_queryEscape(t *testing.T) {
	got := wearPairingURLFromParts("192.168.0.5&evil", "8765")
	u, err := url.Parse(got)
	if err != nil {
		t.Fatal(err)
	}
	if u.Query().Get("host") != "192.168.0.5&evil" {
		t.Fatalf("host: %q", u.Query().Get("host"))
	}
}
