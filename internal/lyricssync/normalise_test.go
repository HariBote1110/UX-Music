package lyricssync

import "testing"

func TestNormaliseText(t *testing.T) {
	input := " Ｈｅｌｌｏ、　WORLD!! "
	got := normaliseText(input)
	want := "helloworld"
	if got != want {
		t.Fatalf("normaliseText() = %q, want %q", got, want)
	}
}

func TestIsInterludeLine(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want bool
	}{
		{name: "blank", in: "   ", want: true},
		{name: "ja", in: "[間奏]", want: true},
		{name: "en", in: "(interlude)", want: true},
		{name: "lyric", in: "こんにちは", want: false},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			if got := isInterludeLine(tt.in); got != tt.want {
				t.Fatalf("isInterludeLine(%q) = %v, want %v", tt.in, got, tt.want)
			}
		})
	}
}
