package cdrip

import (
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// requirePOSIXShellScripts skips tests that stand in for cdparanoia/ffmpeg
// with `#!/bin/sh` scripts, which Windows cannot execute directly. Windows
// builds do not bundle cdparanoia, so the fallback path is not used there.
func requirePOSIXShellScripts(t *testing.T) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("fake cdparanoia/ffmpeg are POSIX shell scripts, which Windows cannot execute")
	}
}

func TestSanitize(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"Hello World", "Hello World"},
		{"AC/DC", "AC_DC"},
		{"What?", "What_"},
		{"<Invalid>", "_Invalid_"},
	}

	for _, test := range tests {
		got := sanitize(test.input)
		if got != test.expected {
			t.Errorf("sanitize(%q) = %q; want %q", test.input, got, test.expected)
		}
	}
}

func TestParseTrackList(t *testing.T) {
	output := `
Ripping from sector       0 (track  1 [0:00.00])
          to sector   19213 (track  1 [4:16.13])

outputting to rip_123_track1.wav

 (== PROGRESS == [                              | 000275 00 ] == :^D * ==)   
									
  1. 19214
  2. 15432
  3. 20000
`
	tracks := parseTrackList(output)
	if len(tracks) != 3 {
		t.Errorf("Expected 3 tracks, got %d", len(tracks))
	}
	if len(tracks) > 0 {
		if tracks[0].Number != 1 || tracks[0].Sectors != 19214 {
			t.Errorf("Track 1 mismatch: %+v", tracks[0])
		}
	}
}

func TestRipperReportsProgressOnCdparanoiaFallback(t *testing.T) {
	requirePOSIXShellScripts(t)
	dir := t.TempDir()
	cdparanoia := filepath.Join(dir, "cdparanoia")
	script := "#!/bin/sh\n"
	script += "if [ \"$1\" = \"-Q\" ]; then printf '  1. 2\\n'; exit 0; fi\n"
	script += "out=\"$3\"\n"
	script += "dd if=/dev/zero of=\"$out\" bs=44 count=1 2>/dev/null\n"
	script += "sleep 0.5\n"
	script += "dd if=/dev/zero bs=2352 count=1 >> \"$out\" 2>/dev/null\n"
	script += "sleep 0.5\n"
	script += "dd if=/dev/zero bs=2352 count=1 >> \"$out\" 2>/dev/null\n"
	if err := os.WriteFile(cdparanoia, []byte(script), 0755); err != nil {
		t.Fatal(err)
	}
	ffmpeg := filepath.Join(dir, "ffmpeg")
	if err := os.WriteFile(ffmpeg, []byte("#!/bin/sh\nlast=\"\"\nfor arg in \"$@\"; do last=\"$arg\"; done\ncp \"$2\" \"$last\"\n"), 0755); err != nil {
		t.Fatal(err)
	}
	r := NewRipper(cdparanoia, ffmpeg, dir)
	progress := make(chan RipProgress, 16)
	_, err := r.StartRip([]Track{{Number: 1, Title: "test", Artist: "artist", Sectors: 2}}, RipOptions{Format: "wav"}, dir, progress)
	if err != nil {
		t.Fatal(err)
	}
	close(progress)
	var sawRipping bool
	for event := range progress {
		if event.Status == "ripping" && event.Percent > 0 && event.Percent < 95 {
			sawRipping = true
		}
	}
	if !sawRipping {
		t.Fatal("cdparanoia fallback emitted no intermediate ripping progress")
	}
}
