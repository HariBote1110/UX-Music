package server

import (
	"testing"
	"ux-music-sidecar/pkg/audio"
)

func TestDeviceFingerprint(t *testing.T) {
	tests := []struct {
		name    string
		devices []audio.Device
		want    string
	}{
		{
			name:    "empty list",
			devices: []audio.Device{},
			want:    "",
		},
		{
			name: "single device",
			devices: []audio.Device{
				{Name: "Speaker 1"},
			},
			want: "Speaker 1",
		},
		{
			name: "multiple devices",
			devices: []audio.Device{
				{Name: "Headphones"},
				{Name: "Speaker 1"},
			},
			want: "Headphones\x00Speaker 1",
		},
		{
			name: "multiple devices requires sorting",
			devices: []audio.Device{
				{Name: "Speaker 1"},
				{Name: "Headphones"},
			},
			want: "Headphones\x00Speaker 1",
		},
		{
			name: "multiple devices with duplicates",
			devices: []audio.Device{
				{Name: "Speaker 1"},
				{Name: "Headphones"},
				{Name: "Speaker 1"},
			},
			want: "Headphones\x00Speaker 1\x00Speaker 1",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := deviceListFingerprint(tt.devices)
			if got != tt.want {
				t.Errorf("deviceListFingerprint() = %v, want %v", got, tt.want)
			}
		})
	}
}

// TestResolveInitialVolume covers the startup-time volume lookup used to fix
// the "起動時に限り音量が壊れる" regression: the Go audio player defaults to
// 1.0 on creation (see pkg/audio.Player.Play calling p.setVolume(1.0)), and
// since the native queue cutover (see progress/native-play-queue.md), Go's
// startQueueItem starts playback directly without ever receiving the saved
// master volume from the renderer. Startup must apply the saved volume
// itself, deterministically, before any playback can start.
func TestResolveInitialVolume(t *testing.T) {
	tests := []struct {
		name     string
		settings map[string]interface{}
		wantVol  float64
		wantOK   bool
	}{
		{
			name:     "valid volume within range",
			settings: map[string]interface{}{"volume": 0.42},
			wantVol:  0.42,
			wantOK:   true,
		},
		{
			name:     "missing volume key",
			settings: map[string]interface{}{"visualizerMode": "active"},
			wantOK:   false,
		},
		{
			name:     "nil settings map",
			settings: nil,
			wantOK:   false,
		},
		{
			name:     "non-numeric volume value",
			settings: map[string]interface{}{"volume": "loud"},
			wantOK:   false,
		},
		{
			name:     "volume above range is clamped",
			settings: map[string]interface{}{"volume": 3.5},
			wantVol:  1.0,
			wantOK:   true,
		},
		{
			name:     "negative volume is clamped",
			settings: map[string]interface{}{"volume": -1.0},
			wantVol:  0.0,
			wantOK:   true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotVol, gotOK := resolveInitialVolume(tt.settings)
			if gotOK != tt.wantOK {
				t.Fatalf("resolveInitialVolume() ok = %v, want %v", gotOK, tt.wantOK)
			}
			if gotOK && gotVol != tt.wantVol {
				t.Errorf("resolveInitialVolume() vol = %v, want %v", gotVol, tt.wantVol)
			}
		})
	}
}
