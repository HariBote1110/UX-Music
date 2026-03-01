package scanner

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestParseLeadingInt(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  int
	}{
		{name: "plain", input: "8", want: 8},
		{name: "with total", input: "8/12", want: 8},
		{name: "with spaces", input: " 03 ", want: 3},
		{name: "invalid", input: "x8", want: 0},
		{name: "empty", input: "", want: 0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseLeadingInt(tt.input)
			if got != tt.want {
				t.Fatalf("parseLeadingInt(%q) = %d, want %d", tt.input, got, tt.want)
			}
		})
	}
}

func TestParseYear(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  int
	}{
		{name: "year only", input: "2023", want: 2023},
		{name: "iso date", input: "2023-11-01", want: 2023},
		{name: "spaced", input: " 2024 ", want: 2024},
		{name: "invalid", input: "abc", want: 0},
		{name: "short", input: "99", want: 0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseYear(tt.input)
			if got != tt.want {
				t.Fatalf("parseYear(%q) = %d, want %d", tt.input, got, tt.want)
			}
		})
	}
}

func TestFirstNonEmptyTag(t *testing.T) {
	tags := map[string]string{
		"title":     "",
		"\u00a9nam": "Sample Song",
	}

	got := firstNonEmptyTag(tags, "title", "\u00a9nam")
	if got != "Sample Song" {
		t.Fatalf("firstNonEmptyTag returned %q, want %q", got, "Sample Song")
	}
}

func TestIsExecutablePath(t *testing.T) {
	dir := t.TempDir()
	execFile := filepath.Join(dir, "exec-bin")
	nonExecFile := filepath.Join(dir, "plain-file")

	if err := os.WriteFile(execFile, []byte("#!/bin/sh\necho ok\n"), 0755); err != nil {
		t.Fatalf("failed to create executable file: %v", err)
	}
	if err := os.WriteFile(nonExecFile, []byte("plain"), 0644); err != nil {
		t.Fatalf("failed to create non-executable file: %v", err)
	}

	if !isExecutablePath(execFile) {
		t.Fatalf("isExecutablePath(%q) = false, want true", execFile)
	}

	if runtime.GOOS != "windows" && isExecutablePath(nonExecFile) {
		t.Fatalf("isExecutablePath(%q) = true, want false", nonExecFile)
	}

	if isExecutablePath(dir) {
		t.Fatalf("isExecutablePath(%q) = true, want false for directory", dir)
	}
}

func TestBuildCommandFallbackCandidates(t *testing.T) {
	binary := commandBinaryName("ffmpeg")
	candidates := buildCommandFallbackCandidates("ffmpeg")

	required := []string{
		filepath.Join("/opt/homebrew/bin", binary),
		filepath.Join("/usr/local/bin", binary),
		filepath.Join("/usr/bin", binary),
	}

	for _, want := range required {
		found := false
		for _, got := range candidates {
			if got == want {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("fallback candidates missing %q", want)
		}
	}
}
