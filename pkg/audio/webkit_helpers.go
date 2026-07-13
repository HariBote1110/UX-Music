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
	return strings.Contains(path, webKitHelperPathMarker)
}

// selfDescendants returns the set of PIDs reachable from selfPID by following
// parent → child edges (selfPID itself is included in the returned set). A
// process is a descendant when its parent chain leads back to selfPID.
func selfDescendants(procs []procInfo, selfPID int) map[int]bool {
	childrenOf := make(map[int][]int, len(procs))
	for _, p := range procs {
		if p.PID == p.PPID {
			// Guard against a self-referential parent edge (PID 0/1 style)
			// which would otherwise spin the traversal.
			continue
		}
		childrenOf[p.PPID] = append(childrenOf[p.PPID], p.PID)
	}

	owned := map[int]bool{selfPID: true}
	queue := []int{selfPID}
	for len(queue) > 0 {
		cur := queue[0]
		queue = queue[1:]
		for _, child := range childrenOf[cur] {
			if owned[child] {
				continue
			}
			owned[child] = true
			queue = append(queue, child)
		}
	}
	return owned
}

// webKitHelperPIDsForSelf selects the WebKit helper processes that belong to
// this application, excluding helpers owned by other apps (e.g. Safari's
// shared WebKit processes). A helper qualifies when its executable is a WebKit
// helper AND it is attributable to us by either of two independent signals:
//
//   - it is a descendant of selfPID in the process tree, or
//   - macOS holds selfPID (or one of our descendants) responsible for it.
//
// The responsibility signal covers XPC-launched helpers whose direct parent is
// launchd rather than our process. Results preserve input order and are
// deduplicated. selfPID itself is never returned.
func webKitHelperPIDsForSelf(procs []procInfo, selfPID int) []int {
	owned := selfDescendants(procs, selfPID)

	var result []int
	seen := make(map[int]bool)
	for _, p := range procs {
		if p.PID == selfPID || seen[p.PID] {
			continue
		}
		if !isWebKitHelperPath(p.Path) {
			continue
		}
		ours := owned[p.PID] || p.ResponsiblePID == selfPID || owned[p.ResponsiblePID]
		if !ours {
			continue
		}
		seen[p.PID] = true
		result = append(result, p.PID)
	}
	return result
}
