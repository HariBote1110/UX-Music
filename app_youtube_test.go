package main

import (
	"testing"
)

func TestNormaliseSettingValue(t *testing.T) {
	tests := []struct {
		name     string
		value    interface{}
		fallback string
		want     string
	}{
		{
			name:     "valid string",
			value:    "  FULL  ",
			fallback: "download",
			want:     "full",
		},
		{
			name:     "valid string already normalized",
			value:    "audio_only",
			fallback: "full",
			want:     "audio_only",
		},
		{
			name:     "empty string",
			value:    "",
			fallback: "download",
			want:     "download",
		},
		{
			name:     "whitespace string",
			value:    "   \n\t ",
			fallback: "fallback_val",
			want:     "fallback_val",
		},
		{
			name:     "nil value",
			value:    nil,
			fallback: "default",
			want:     "default",
		},
		{
			name:     "integer value",
			value:    123,
			fallback: "default",
			want:     "default",
		},
		{
			name:     "boolean value",
			value:    true,
			fallback: "default",
			want:     "default",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := normaliseSettingValue(tt.value, tt.fallback)
			if got != tt.want {
				t.Errorf("normaliseSettingValue() = %v, want %v", got, tt.want)
			}
		})
	}
}
