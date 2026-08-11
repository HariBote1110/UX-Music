package server

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"

	"ux-music-sidecar/internal/config"
)

// launchAgentLabel is both the LaunchAgent plist's Label and the last path
// component launchctl uses to address the loaded service
// (gui/$UID/com.uxmusic.serve). See markdown/appletv-servermode-plan.md
// Phase 0-3.
const launchAgentLabel = "com.uxmusic.serve"

// launchAgentRunner abstracts the two launchctl subcommands the resident
// agent needs. Production code uses execLaunchAgentRunner; tests stub this
// out entirely so they never touch the real launchd on the developer's
// machine (the real GUI app on this machine is bound to port 8765 and must
// never be disturbed by a test run).
type launchAgentRunner interface {
	Bootstrap(uid string, plistPath string) error
	Bootout(uid string, label string) error
}

// execLaunchAgentRunner is the real implementation, shelling out to
// launchctl. Nothing in this package invokes it directly outside of the
// package-level currentLaunchAgentRunner variable, so tests can swap it out.
type execLaunchAgentRunner struct{}

func (execLaunchAgentRunner) Bootstrap(uid string, plistPath string) error {
	cmd := exec.Command("launchctl", "bootstrap", "gui/"+uid, plistPath)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("launchctl bootstrap: %w (%s)", err, string(out))
	}
	return nil
}

func (execLaunchAgentRunner) Bootout(uid string, label string) error {
	cmd := exec.Command("launchctl", "bootout", "gui/"+uid+"/"+label)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("launchctl bootout: %w (%s)", err, string(out))
	}
	return nil
}

// currentLaunchAgentRunner is the seam every launchctl call in this package
// goes through. Tests replace it with a stub; production code leaves it as
// execLaunchAgentRunner.
var currentLaunchAgentRunner launchAgentRunner = execLaunchAgentRunner{}

// launchAgentPlistPath returns the fixed install location for the resident
// LaunchAgent plist: ~/Library/LaunchAgents/com.uxmusic.serve.plist.
func launchAgentPlistPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Library", "LaunchAgents", launchAgentLabel+".plist"), nil
}

// generateLaunchAgentPlist is a pure function returning the plist XML for
// the resident `--serve` agent, so it can be unit-tested without touching
// the filesystem or launchd. executablePath is the current binary
// (os.Executable()); userDataPath is the ux-music user data directory
// (internal/config.GetUserDataPath()) that logs/serve.log and
// logs/serve.err.log are written under.
func generateLaunchAgentPlist(executablePath string, userDataPath string) string {
	stdout := filepath.Join(userDataPath, "logs", "serve.log")
	stderr := filepath.Join(userDataPath, "logs", "serve.err.log")
	return fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>%s</string>
	<key>ProgramArguments</key>
	<array>
		<string>%s</string>
		<string>--serve</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardOutPath</key>
	<string>%s</string>
	<key>StandardErrorPath</key>
	<string>%s</string>
</dict>
</plist>
`, launchAgentLabel, executablePath, stdout, stderr)
}

// installLaunchAgent writes the LaunchAgent plist and bootstraps it via
// launchctl (through currentLaunchAgentRunner). Backs `--install-agent`.
func installLaunchAgent() error {
	exePath, err := os.Executable()
	if err != nil {
		return err
	}
	plistPath, err := launchAgentPlistPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(plistPath), 0o755); err != nil {
		return err
	}
	content := generateLaunchAgentPlist(exePath, config.GetUserDataPath())
	if err := os.WriteFile(plistPath, []byte(content), 0o644); err != nil {
		return err
	}
	uid := strconv.Itoa(os.Getuid())
	return currentLaunchAgentRunner.Bootstrap(uid, plistPath)
}

// uninstallLaunchAgent boots the resident agent out via launchctl and
// removes the plist. Backs `--uninstall-agent`. A missing plist is not an
// error (it may have been removed already, or the bootout is being retried
// after a partial failure); the bootout is still attempted unconditionally.
func uninstallLaunchAgent() error {
	uid := strconv.Itoa(os.Getuid())
	bootoutErr := currentLaunchAgentRunner.Bootout(uid, launchAgentLabel)

	plistPath, err := launchAgentPlistPath()
	if err != nil {
		if bootoutErr != nil {
			return bootoutErr
		}
		return err
	}
	removeErr := os.Remove(plistPath)
	if removeErr != nil && !os.IsNotExist(removeErr) {
		if bootoutErr != nil {
			return bootoutErr
		}
		return removeErr
	}
	return bootoutErr
}
