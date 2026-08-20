//go:build !darwin

package server

// registerAppVisibilityObserver is a no-op off darwin: there is no
// NSApplicationDidHide/DidUnhide equivalent wired up on other platforms
// (matches os_media_stub.go's precedent). Phase 2 WebView parking is
// darwin-only for now — see markdown/background-native-queue-plan.md.
func registerAppVisibilityObserver(callback func(hidden bool)) {
	_ = callback
}
