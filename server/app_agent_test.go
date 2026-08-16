package server

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// stubLaunchAgentRunner records the calls made to it instead of touching the
// real launchd on this machine. Tests must never let production code reach
// execLaunchAgentRunner.
type stubLaunchAgentRunner struct {
	bootstrapCalls []string // plist paths passed to Bootstrap
	bootoutCalls   []string // labels passed to Bootout
	bootstrapErr   error
	bootoutErr     error
}

func (s *stubLaunchAgentRunner) Bootstrap(uid string, plistPath string) error {
	s.bootstrapCalls = append(s.bootstrapCalls, plistPath)
	return s.bootstrapErr
}

func (s *stubLaunchAgentRunner) Bootout(uid string, label string) error {
	s.bootoutCalls = append(s.bootoutCalls, label)
	return s.bootoutErr
}

func withStubLaunchAgentRunner(t *testing.T, stub *stubLaunchAgentRunner) {
	t.Helper()
	previous := currentLaunchAgentRunner
	currentLaunchAgentRunner = stub
	t.Cleanup(func() { currentLaunchAgentRunner = previous })
}

func TestGenerateLaunchAgentPlist_ContainsExpectedFields(t *testing.T) {
	content := generateLaunchAgentPlist("/usr/local/bin/ux-music", "/tmp/ux-music-userdata")

	mustContain := []string{
		"<key>Label</key>",
		"<string>com.uxmusic.serve</string>",
		"<key>ProgramArguments</key>",
		"<string>/usr/local/bin/ux-music</string>",
		"<string>--serve</string>",
		"<key>RunAtLoad</key>",
		"<key>KeepAlive</key>",
		"<key>StandardOutPath</key>",
		filepath.Join("/tmp/ux-music-userdata", "logs", "serve.log"),
		"<key>StandardErrorPath</key>",
		filepath.Join("/tmp/ux-music-userdata", "logs", "serve.err.log"),
	}
	for _, want := range mustContain {
		if !strings.Contains(content, want) {
			t.Fatalf("expected generated plist to contain %q, got:\n%s", want, content)
		}
	}
}

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

func TestUninstallLaunchAgent_MissingPlistIsNotAnError(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	stub := &stubLaunchAgentRunner{}
	withStubLaunchAgentRunner(t, stub)

	// No install first: the plist does not exist. Uninstall should still
	// attempt the bootout (in case the agent was installed by another means)
	// and must not fail merely because the plist file is already gone.
	if err := uninstallLaunchAgent(); err != nil {
		t.Fatalf("uninstallLaunchAgent should tolerate a missing plist, got error: %v", err)
	}
	if len(stub.bootoutCalls) != 1 {
		t.Fatalf("expected Bootout to still be attempted, got %v", stub.bootoutCalls)
	}
}
