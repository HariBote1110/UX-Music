package main

import (
	"reflect"
	"testing"
)

func TestHasNumericLoudnessValue(t *testing.T) {
	tests := []struct {
		name  string
		value interface{}
		want  bool
	}{
		{name: "float64", value: float64(-12.3), want: true},
		{name: "int", value: int(-10), want: true},
		{name: "string", value: "-12.3", want: false},
		{name: "nil", value: nil, want: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := hasNumericLoudnessValue(tt.value)
			if got != tt.want {
				t.Fatalf("hasNumericLoudnessValue(%v) = %v, want %v", tt.value, got, tt.want)
			}
		})
	}
}

func TestFilterPendingLoudnessPaths(t *testing.T) {
	paths := []string{
		"",
		"  /music/a.flac  ",
		"/music/b.flac",
		"/music/a.flac",
		"/music/c.flac",
	}
	existing := map[string]interface{}{
		"/music/a.flac": float64(-11.2),
		"/music/c.flac": "pending",
	}

	got := filterPendingLoudnessPaths(paths, existing)
	want := []string{"/music/b.flac", "/music/c.flac"}

	if !reflect.DeepEqual(got, want) {
		t.Fatalf("filterPendingLoudnessPaths() = %#v, want %#v", got, want)
	}
}
