package scanner

import "testing"

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
