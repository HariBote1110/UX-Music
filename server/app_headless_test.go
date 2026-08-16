package server

import (
	"context"
	"testing"
)

// TestHeadlessEmitDoesNotPanic verifies that a plain NewApp(), used without
// ever calling Startup (the headless / --serve path — see
// markdown/appletv-servermode-plan.md Phase 0-1), can emit events through
// a.emit without panicking, both before and after a context is attached.
func TestHeadlessEmitDoesNotPanic(t *testing.T) {
	a := NewApp()

	// No context attached yet (Startup not called): emit must be a safe no-op.
	a.emit("scan-complete", []interface{}{"song-1"})
	a.emit("audio-playback-finished", nil)

	// Once a context is attached (as happens in headless --serve startup,
	// without ever wiring the Wails adapter), emit must still be a no-op
	// rather than reaching for a nil Wails runtime.
	a.ctx = context.Background()
	a.emit("play-counts-updated", map[string]interface{}{"song-1": 3})
}

// TestHeadlessDialogsRequireGUI verifies that dialog operations on a plain
// NewApp() (headless) fail with ErrGUIRequired instead of touching the
// Wails runtime.
func TestHeadlessDialogsRequireGUI(t *testing.T) {
	a := NewApp()
	ctx := context.Background()

	if _, err := a.dialogs.OpenFileDialog(ctx, DialogOptions{Title: "test"}); err != ErrGUIRequired {
		t.Fatalf("OpenFileDialog: expected ErrGUIRequired, got %v", err)
	}
	if _, err := a.dialogs.OpenMultipleFilesDialog(ctx, DialogOptions{Title: "test"}); err != ErrGUIRequired {
		t.Fatalf("OpenMultipleFilesDialog: expected ErrGUIRequired, got %v", err)
	}
	if _, err := a.dialogs.OpenDirectoryDialog(ctx, DialogOptions{Title: "test"}); err != ErrGUIRequired {
		t.Fatalf("OpenDirectoryDialog: expected ErrGUIRequired, got %v", err)
	}

	// Public methods that wrap dialogs must surface the same error headlessly.
	if _, err := a.SelectNormalizeOutputFolder(); err != ErrGUIRequired {
		t.Fatalf("SelectNormalizeOutputFolder: expected ErrGUIRequired, got %v", err)
	}
}
