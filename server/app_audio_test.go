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
			got := deviceFingerprint(tt.devices)
			if got != tt.want {
				t.Errorf("deviceFingerprint() = %v, want %v", got, tt.want)
			}
		})
	}
}
