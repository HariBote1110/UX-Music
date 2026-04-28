package lyricssync

import "testing"

func TestNormaliseLanguageHint(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{in: "", want: "auto"},
		{in: " auto ", want: "auto"},
		{in: "auto-ja", want: "ja"},
		{in: "auto-en", want: "en"},
		{in: "JA", want: "ja"},
		{in: "en", want: "en"},
	}

	for _, tc := range cases {
		if got := normaliseLanguageHint(tc.in); got != tc.want {
			t.Fatalf("normaliseLanguageHint(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
