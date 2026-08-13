package server

import "testing"

// BeforeClose is wired to wails' OnBeforeClose hook. Window-close (the red
// traffic-light button) never reaches this hook at all — it is intercepted
// natively on macOS by HideWindowOnClose (see WindowDelegate.m), which hides
// the window instead of closing it. OnBeforeClose is therefore only invoked
// for genuine quit intents (Cmd+Q, the App-menu Quit item, the Dock icon's
// "Quit" context item, and OS logout/shutdown via
// applicationShouldTerminate). BeforeClose must never prevent those, or the
// app would hang the OS logout/shutdown sequence.
func TestApp_BeforeClose_AllowsRealQuit(t *testing.T) {
	a := &App{}

	prevented := a.BeforeClose(nil)

	if prevented {
		t.Fatalf("BeforeClose() = true (prevented close); want false so that Cmd+Q / menu Quit / OS shutdown always succeed")
	}
}
