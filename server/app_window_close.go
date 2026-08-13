package server

import "context"

// BeforeClose is wired to wails' options.App.OnBeforeClose hook in main.go.
//
// On macOS the window's traffic-light close button is intercepted natively
// by options.App.HideWindowOnClose: WindowDelegate.m hides the window
// (via [NSApp hide:nil]) and returns before ever sending the "Q" message
// that reaches this hook. Clicking the Dock icon afterwards makes AppKit
// unhide the app on its own (standard NSApplication behaviour), so no
// custom re-show wiring is required either.
//
// OnBeforeClose is only invoked for genuine quit intents: Cmd+Q / the
// App-menu Quit item (both routed through the "Quit " + app name menu item
// added by menu.AppMenu() in main.go), the Dock icon's "Quit" context item,
// and applicationShouldTerminate fired by OS logout/shutdown. All of these
// must be allowed to succeed unconditionally — returning true here would
// make the OS logout/shutdown sequence hang waiting for this app to quit.
func (a *App) BeforeClose(ctx context.Context) bool {
	return false
}
