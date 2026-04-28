package lyricssync

import "testing"

func TestNormaliseSidecarRuntimePreference(t *testing.T) {
	cases := map[string]string{
		"":        sidecarRuntimeAuto,
		"auto":    sidecarRuntimeAuto,
		"python":  sidecarRuntimePython,
		"swift":   sidecarRuntimeSwift,
		"SWIFT":   sidecarRuntimeSwift,
		"unknown": sidecarRuntimeAuto,
	}
	for input, want := range cases {
		if got := normaliseSidecarRuntimePreference(input); got != want {
			t.Fatalf("input=%q got=%q want=%q", input, got, want)
		}
	}
}

func TestShouldUseSwiftRuntime(t *testing.T) {
	cases := []struct {
		name            string
		goos            string
		preference      string
		swiftConfigured bool
		want            bool
	}{
		{name: "darwin explicit swift", goos: "darwin", preference: "swift", swiftConfigured: false, want: true},
		{name: "darwin auto with binary", goos: "darwin", preference: "auto", swiftConfigured: true, want: true},
		{name: "darwin auto without binary", goos: "darwin", preference: "auto", swiftConfigured: false, want: false},
		{name: "linux explicit swift", goos: "linux", preference: "swift", swiftConfigured: true, want: false},
		{name: "python explicit", goos: "darwin", preference: "python", swiftConfigured: true, want: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := shouldUseSwiftRuntime(tc.goos, tc.preference, tc.swiftConfigured); got != tc.want {
				t.Fatalf("got=%v want=%v", got, tc.want)
			}
		})
	}
}
