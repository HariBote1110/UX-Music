package server

import (
	"testing"
)

func TestBytesToMB(t *testing.T) {
	tests := []struct {
		name  string
		value uint64
		want  float64
	}{
		{name: "zero", value: 0, want: 0.0},
		{name: "exact megabyte", value: 1048576, want: 1.0},
		{name: "fractional megabyte", value: 1572864, want: 1.5},
		{name: "large value 1GB", value: 1073741824, want: 1024.0},
		{name: "small value", value: 1024, want: 0.0009765625},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := bytesToMB(tt.value)
			if got != tt.want {
				t.Errorf("bytesToMB(%v) = %v, want %v", tt.value, got, tt.want)
			}
		})
	}
}
