//go:build darwin

package server

import (
	"os"
	"regexp"
	"testing"
)

// TestTrayDarwinCgoUsesARC guards against the regression where
// server/tray_darwin.m (written in ARC style) was compiled under MRC
// because the package's #cgo CFLAGS lacked -fobjc-arc. Under MRC, the
// autoreleased NSStatusItem returned by statusItemWithLength: was
// deallocated before it could be displayed, so the menu-bar tray icon
// never appeared. See progress/tray-arc-retain.md.
func TestTrayDarwinCgoUsesARC(t *testing.T) {
	source, err := os.ReadFile("tray_darwin.go")
	if err != nil {
		t.Fatalf("failed to read tray_darwin.go: %v", err)
	}

	cflagsLine := regexp.MustCompile(`(?m)^#cgo CFLAGS:.*$`).FindString(string(source))
	if cflagsLine == "" {
		t.Fatal("tray_darwin.go: no '#cgo CFLAGS' line found")
	}

	if !regexp.MustCompile(`-fobjc-arc\b`).MatchString(cflagsLine) {
		t.Fatalf("tray_darwin.go: #cgo CFLAGS line is missing -fobjc-arc, so tray_darwin.m compiles under MRC and NSStatusItem is released before it is shown: %q", cflagsLine)
	}
}
