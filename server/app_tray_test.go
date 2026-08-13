package server

import "testing"

func TestTrayPlayPauseLabel(t *testing.T) {
	cases := []struct {
		name    string
		playing bool
		want    string
	}{
		{name: "playing shows pause action", playing: true, want: "一時停止"},
		{name: "paused shows play action", playing: false, want: "再生"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := trayPlayPauseLabel(tc.playing)
			if got != tc.want {
				t.Errorf("trayPlayPauseLabel(%v) = %q, want %q", tc.playing, got, tc.want)
			}
		})
	}
}
