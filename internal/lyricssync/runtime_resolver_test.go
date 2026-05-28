package lyricssync

import (
	"context"
	"fmt"
	"testing"
	"time"
)

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
		{name: "darwin auto with swift available", goos: "darwin", preference: "auto", swiftConfigured: true, want: true},
		{name: "darwin auto without swift available", goos: "darwin", preference: "auto", swiftConfigured: false, want: false},
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

func TestResolveSidecarSpecDoesNotForceMediumForFastProfile(t *testing.T) {
	t.Setenv(envLyricsRuntime, sidecarRuntimePython)
	t.Setenv("UX_MUSIC_LYRICS_SYNC_DUMMY", "1")

	req := Request{Lines: []string{"hello"}, Profile: "fast"}
	if _, err := resolveSidecarSpec(&req); err != nil {
		t.Fatal(err)
	}
	if req.WhisperModel != "" {
		t.Fatalf("profile=fast should let sidecars choose a light model, got forced whisperModel=%q", req.WhisperModel)
	}
}

func TestShouldAutoFallbackToPython(t *testing.T) {
	if !shouldAutoFallbackToPython(
		sidecarSpec{runtimeName: sidecarRuntimeSwift},
		sidecarRuntimeAuto,
		&sidecarError{kind: sidecarFailureStart, err: fmt.Errorf("binary missing")},
	) {
		t.Fatal("起動失敗はフォールバック可の想定です")
	}
	if shouldAutoFallbackToPython(
		sidecarSpec{runtimeName: sidecarRuntimeSwift},
		sidecarRuntimeSwift,
		&sidecarError{kind: sidecarFailureStart, err: nil},
	) {
		t.Fatal("runtime=swift 明示時はフォールバックしません")
	}
	if shouldAutoFallbackToPython(
		sidecarSpec{runtimeName: sidecarRuntimePython},
		sidecarRuntimeAuto,
		&sidecarError{kind: sidecarFailureStart, err: nil},
	) {
		t.Fatal("Python 実行時はフォールバック不要です")
	}
	if shouldAutoFallbackToPython(
		sidecarSpec{runtimeName: sidecarRuntimeSwift},
		sidecarRuntimeAuto,
		&sidecarError{kind: sidecarFailureWait, err: context.DeadlineExceeded},
	) {
		t.Fatal("タイムアウト時はフォールバックしません")
	}
	if shouldAutoFallbackToPython(
		sidecarSpec{runtimeName: sidecarRuntimeSwift},
		sidecarRuntimeAuto,
		&sidecarError{kind: sidecarFailureWait, err: nil},
	) {
		t.Fatal("業務エラー相当の wait 失敗ではフォールバックしません")
	}
	if !shouldAutoFallbackToPython(
		sidecarSpec{runtimeName: sidecarRuntimeSwift},
		sidecarRuntimeAuto,
		&sidecarError{kind: sidecarFailureDecode, err: fmt.Errorf("bad json")},
	) {
		t.Fatal("JSON decode 失敗はフォールバック可の想定です")
	}
}

func TestDeriveFallbackContext(t *testing.T) {
	parent, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	ctx, childCancel, ok := deriveFallbackContext(parent, 10*time.Minute)
	if !ok {
		t.Fatal("十分な残り時間がある場合はフォールバック可能の想定です")
	}
	defer childCancel()

	deadline, ok := ctx.Deadline()
	if !ok {
		t.Fatal("deadline を継承する想定です")
	}
	parentDeadline, _ := parent.Deadline()
	if !deadline.Equal(parentDeadline) {
		t.Fatalf("fallback deadline mismatch: got=%v want=%v", deadline, parentDeadline)
	}

	shortParent, shortCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer shortCancel()

	if ctx, cancel, ok := deriveFallbackContext(shortParent, 10*time.Minute); ok || ctx != nil || cancel != nil {
		t.Fatal("残り時間が少ない場合はフォールバックしません")
	}
}
