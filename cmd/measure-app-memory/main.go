// cmd/measure-app-memory prints the PIDs of the WebKit helper processes
// (WebContent/GPU/Networking) attributed to a given target PID, reusing the
// exact ownership logic pkg/audio uses to target the WebView-tap
// (WebKitHelperPIDsFor, generalised from WebKitHelperPIDs — see
// cmd/webkit-helpers for the self-targeted verification tool this is
// modelled on).
//
// It backs scripts/measure-app-memory.sh (progress/webview-parking.md,
// markdown/background-native-queue-plan.md Phase 2 §E): the shell script
// resolves UX-Music.app's own PID, calls this tool to find its WebKit
// helpers, then sums RSS across all of them via ps.
//
// Usage:
//
//	go run ./cmd/measure-app-memory --pid <PID>
//
// Prints one PID per line to stdout (nothing else), so the shell script can
// consume it directly without parsing.
package main

import (
	"flag"
	"fmt"
	"os"

	"ux-music-sidecar/pkg/audio"
)

func main() {
	pid := flag.Int("pid", 0, "target process PID to find WebKit helpers for")
	flag.Parse()

	if *pid <= 0 {
		fmt.Fprintln(os.Stderr, "usage: measure-app-memory --pid <PID>")
		os.Exit(2)
	}

	pids, err := audio.WebKitHelperPIDsFor(*pid)
	if err != nil {
		fmt.Fprintf(os.Stderr, "WebKitHelperPIDsFor failed: %v\n", err)
		os.Exit(1)
	}
	for _, p := range pids {
		fmt.Println(p)
	}
}
