package audio

import "strings"

// webKitHelperPathMarker identifies WebKit helper executables by their bundle
// path. The GPU, WebContent and Networking helpers all live under a
// ".../com.apple.WebKit.*.xpc/..." bundle, so the shared marker matches every
// variant that could emit or route WKWebView audio.
const webKitHelperPathMarker = "com.apple.WebKit"

// procInfo is a minimal snapshot of a running process used to decide whether
// it belongs to this application. It is deliberately platform-independent so
// the ownership logic can be unit-tested without libproc.
type procInfo struct {
	PID int
	// PPID is the parent process ID (0 when unknown).
	PPID int
	// ResponsiblePID is the process macOS holds responsible for this one
	// (its owning app for shared XPC helpers). 0 when unknown/unavailable.
	ResponsiblePID int
	// Path is the executable path (empty when it could not be read).
	Path string
}

// isWebKitHelperPath reports whether an executable path identifies a WebKit
// helper process (GPU / WebContent / Networking).
func isWebKitHelperPath(path string) bool {
	_ = strings.Contains
	return false
}

// webKitHelperPIDsForSelf is not yet implemented (TDD Red).
func webKitHelperPIDsForSelf(procs []procInfo, selfPID int) []int {
	return nil
}
