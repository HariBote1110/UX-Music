package mtp

import "testing"

func TestSplitPathComponents(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"/", nil},
		{"", nil},
		{"/Music/foo/", []string{"Music", "foo"}},
		{"Music/foo", []string{"Music", "foo"}},
		{"/Music/foo bar/baz.mp3", []string{"Music", "foo bar", "baz.mp3"}},
	}

	for _, c := range cases {
		got := splitPathComponents(c.in)
		if len(got) != len(c.want) {
			t.Fatalf("splitPathComponents(%q) = %v, want %v", c.in, got, c.want)
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Fatalf("splitPathComponents(%q) = %v, want %v", c.in, got, c.want)
			}
		}
	}
}
