//go:build darwin

package server

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// These two tests exercise launchAgentPlistPath, which resolves via
// os.UserHomeDir(). t.Setenv("HOME", ...) only redirects that on POSIX —
// os.UserHomeDir() on Windows reads %USERPROFILE%, not $HOME — so on
// Windows the plist would be written to the real user's profile directory
// instead of the test's temp dir, and these tests would fail (or worse,
// touch real files) for reasons unrelated to the behaviour under test.
// launchd itself is macOS-only, so there is nothing meaningful to verify
// here on Windows or Linux; constrain the whole file to darwin.

func TestInstallLaunchAgent_WritesPlistAndBootstraps(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	stub := &stubLaunchAgentRunner{}
	withStubLaunchAgentRunner(t, stub)

	if err := installLaunchAgent(); err != nil {
		t.Fatalf("installLaunchAgent returned error: %v", err)
	}

	plistPath := filepath.Join(home, "Library", "LaunchAgents", "com.uxmusic.serve.plist")
	data, err := os.ReadFile(plistPath)
	if err != nil {
		t.Fatalf("expected plist to be written to %s: %v", plistPath, err)
	}
	if !strings.Contains(string(data), "com.uxmusic.serve") {
		t.Fatalf("written plist missing label, got:\n%s", string(data))
	}

	if len(stub.bootstrapCalls) != 1 {
		t.Fatalf("expected exactly one Bootstrap call, got %d", len(stub.bootstrapCalls))
	}
	if stub.bootstrapCalls[0] != plistPath {
		t.Fatalf("expected Bootstrap to be called with %s, got %s", plistPath, stub.bootstrapCalls[0])
	}
	if len(stub.bootoutCalls) != 0 {
		t.Fatalf("installLaunchAgent must not call Bootout, got %v", stub.bootoutCalls)
	}
}

func TestUninstallLaunchAgent_RemovesPlistAndBootsOut(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	stub := &stubLaunchAgentRunner{}
	withStubLaunchAgentRunner(t, stub)

	if err := installLaunchAgent(); err != nil {
		t.Fatalf("installLaunchAgent returned error: %v", err)
	}
	plistPath := filepath.Join(home, "Library", "LaunchAgents", "com.uxmusic.serve.plist")
	if _, err := os.Stat(plistPath); err != nil {
		t.Fatalf("expected plist to exist before uninstall: %v", err)
	}

	if err := uninstallLaunchAgent(); err != nil {
		t.Fatalf("uninstallLaunchAgent returned error: %v", err)
	}

	if _, err := os.Stat(plistPath); !os.IsNotExist(err) {
		t.Fatalf("expected plist to be removed after uninstall, stat err: %v", err)
	}
	if len(stub.bootoutCalls) != 1 || stub.bootoutCalls[0] != launchAgentLabel {
		t.Fatalf("expected exactly one Bootout call with label %s, got %v", launchAgentLabel, stub.bootoutCalls)
	}
}
