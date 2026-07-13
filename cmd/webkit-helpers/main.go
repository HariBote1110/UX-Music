//go:build darwin

// Verification tool for the WebView-tap ownership filter.
//
// It lists every WebKit helper process on the system with its parent PID,
// responsible PID and executable path, and marks which ones the ownership
// filter attributes to *this* process. Because this tool hosts no WKWebView,
// none of the system's WebKit helpers are its descendants — so it prints them
// all as NOT owned, demonstrating that another app's shared WebKit helpers
// (e.g. Safari's) are correctly excluded from our tap targeting.
//
// Usage:
//
//	go run ./cmd/webkit-helpers          # list all WebKit helpers + attribution
//
// Compare the count with Safari open vs. closed: Safari's helpers appear
// (attributed to Safari via ResponsiblePID) but are never owned by this tool.
package main

import (
	"fmt"
	"os"

	"ux-music-sidecar/pkg/audio"
)

func main() {
	diags, err := audio.WebKitHelperDiagnostics()
	if err != nil {
		fmt.Fprintf(os.Stderr, "WebKit ヘルパー列挙に失敗: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("この検証ツールの PID=%d\n", os.Getpid())
	fmt.Printf("システム上の WebKit ヘルパープロセス: %d 件\n\n", len(diags))

	ownedByThisTool := 0
	for _, d := range diags {
		owned := "no"
		if d.OwnedBySelf {
			owned = "YES"
			ownedByThisTool++
		}
		fmt.Printf("  PID=%-6d PPID=%-6d RESP=%-6d owned=%-3s %s\n",
			d.PID, d.PPID, d.ResponsiblePID, owned, d.Path)
	}

	fmt.Printf("\nこのツールが対象とする WebKit ヘルパー: %d 件\n", ownedByThisTool)
	fmt.Println("（WKWebView を持たないため 0 件が正常。他アプリの共有ヘルパーが除外される証左）")

	// Also exercise the exact function the app uses at tap start.
	pids, err := audio.WebKitHelperPIDs()
	if err != nil {
		fmt.Fprintf(os.Stderr, "WebKitHelperPIDs 失敗: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("WebKitHelperPIDs()（アプリがタップ対象に渡す PID 群）= %v\n", pids)
}
