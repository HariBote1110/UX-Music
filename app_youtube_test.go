package main

import (
	"testing"
)

func TestExtractStringFromMap(t *testing.T) {
	tests := []struct {
		name     string
		data     map[string]interface{}
		keys     []string
		expected string
	}{
		{
			name:     "empty map",
			data:     map[string]interface{}{},
			keys:     []string{"key1"},
			expected: "",
		},
		{
			name: "single key found",
			data: map[string]interface{}{
				"key1": "value1",
			},
			keys:     []string{"key1"},
			expected: "value1",
		},
		{
			name: "single key found with surrounding spaces",
			data: map[string]interface{}{
				"key1": "  value1  ",
			},
			keys:     []string{"key1"},
			expected: "value1",
		},
		{
			name: "multiple keys, first found",
			data: map[string]interface{}{
				"key1": "value1",
				"key2": "value2",
			},
			keys:     []string{"key1", "key2"},
			expected: "value1",
		},
		{
			name: "multiple keys, second found",
			data: map[string]interface{}{
				"key2": "value2",
			},
			keys:     []string{"key1", "key2"},
			expected: "value2",
		},
		{
			name: "key found but not a string",
			data: map[string]interface{}{
				"key1": 123,
				"key2": "value2",
			},
			keys:     []string{"key1", "key2"},
			expected: "value2",
		},
		{
			name: "key found but empty string",
			data: map[string]interface{}{
				"key1": "",
				"key2": "value2",
			},
			keys:     []string{"key1", "key2"},
			expected: "value2",
		},
		{
			name: "key found but only spaces",
			data: map[string]interface{}{
				"key1": "   ",
				"key2": "value2",
			},
			keys:     []string{"key1", "key2"},
			expected: "value2",
		},
		{
			name: "no keys match",
			data: map[string]interface{}{
				"key3": "value3",
			},
			keys:     []string{"key1", "key2"},
			expected: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := extractStringFromMap(tt.data, tt.keys...)
			if result != tt.expected {
				t.Errorf("extractStringFromMap() = %v, want %v", result, tt.expected)
			}
		})
	}
}

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
