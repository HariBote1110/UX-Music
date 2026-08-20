package server

// This file is the sole GUI adapter for the server package: it is the only
// file permitted to import the Wails runtime (see markdown/appletv-servermode-plan.md,
// Phase 0-1). Everything else in server/ must stay headless-safe.

import (
	"context"

	wailsRuntime "github.com/wailsapp/wails/v2/pkg/runtime"
)

// wailsDialogProvider backs DialogProvider with real native dialogs via
// Wails. Only wired in while running under the GUI (see wireWailsRuntime).
type wailsDialogProvider struct{}

func (wailsDialogProvider) OpenFileDialog(ctx context.Context, opts DialogOptions) (string, error) {
	return wailsRuntime.OpenFileDialog(ctx, toWailsDialogOptions(opts))
}

func (wailsDialogProvider) OpenMultipleFilesDialog(ctx context.Context, opts DialogOptions) ([]string, error) {
	return wailsRuntime.OpenMultipleFilesDialog(ctx, toWailsDialogOptions(opts))
}

func (wailsDialogProvider) OpenDirectoryDialog(ctx context.Context, opts DialogOptions) (string, error) {
	return wailsRuntime.OpenDirectoryDialog(ctx, toWailsDialogOptions(opts))
}

func toWailsDialogOptions(opts DialogOptions) wailsRuntime.OpenDialogOptions {
	filters := make([]wailsRuntime.FileFilter, len(opts.Filters))
	for i, f := range opts.Filters {
		filters[i] = wailsRuntime.FileFilter{DisplayName: f.DisplayName, Pattern: f.Pattern}
	}
	return wailsRuntime.OpenDialogOptions{
		Title:            opts.Title,
		Filters:          filters,
		DefaultDirectory: opts.DefaultDirectory,
	}
}

// windowUnloadWebViewFunc/windowReloadWebViewFunc are the process-wide
// indirection for the Wails fork's webview-destroy runtime calls (Phase 3 of
// markdown/background-native-queue-plan.md — see FORK_NOTES.md in the
// HariBote1110/wails fork this module's go.mod replace points at), mirroring
// eventsEmitFunc above: default to no-ops so app_park.go stays headless-safe
// and unit-testable, rewired to the real wailsRuntime functions by
// wireWailsRuntime. This indirection also matters for a subtler reason than
// headless-safety: calling wailsRuntime.WindowUnloadWebView/WindowReloadWebView
// with a context.Context that was never registered with a real Wails
// frontend (e.g. a bare context.Background() in a unit test) makes
// getFrontend (v2/pkg/runtime/runtime.go) call log.Fatalf and kill the whole
// test binary — routing app_park.go through these vars instead of importing
// wailsRuntime directly (which this file alone is permitted to do, see the
// file-level comment above) is what keeps server_test's `go test ./...`
// safe.
var windowUnloadWebViewFunc = func(context.Context) {}
var windowReloadWebViewFunc = func(context.Context) {}

// wireWailsRuntime switches the process-wide event emitter, webview-lifecycle
// hooks, and this App's dialog provider over to their Wails-backed
// implementations. It is called once from Startup, which is only ever
// invoked in GUI mode; headless (--serve) runs never call it, so
// eventsEmitFunc/windowUnloadWebViewFunc/windowReloadWebViewFunc stay no-ops
// and dialogs stay a headlessDialogProvider that returns ErrGUIRequired.
func (a *App) wireWailsRuntime() {
	eventsEmitFunc = func(ctx context.Context, name string, data interface{}) {
		if data == nil {
			wailsRuntime.EventsEmit(ctx, name)
			return
		}
		wailsRuntime.EventsEmit(ctx, name, data)
	}
	windowUnloadWebViewFunc = wailsRuntime.WindowUnloadWebView
	windowReloadWebViewFunc = wailsRuntime.WindowReloadWebView
	a.dialogs = wailsDialogProvider{}
}

// trayShowWindow re-shows the app after HideWindowOnClose hid it via
// [NSApp hide:]. runtime.Show reaches Frontend.Show -> mainWindow.ShowApplication
// -> [NSApplication unhide:self] on darwin, which is the counterpart to that
// hide call (see progress/menubar-tray-mode.md and
// progress/background-window-close.md).
func (a *App) trayShowWindow() {
	wailsRuntime.Show(a.ctx)
}

// trayQuit triggers the same real-quit path as Cmd+Q / the App-menu Quit
// item.
func (a *App) trayQuit() {
	wailsRuntime.Quit(a.ctx)
}
