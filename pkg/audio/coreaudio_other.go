//go:build !darwin

package audio

// SystemDefaultOutputName returns the live system default output device name.
// On non-darwin platforms PortAudio's reported default is used at the call
// site, so this stub returns an empty string to indicate "no live source".
func SystemDefaultOutputName() string {
	return ""
}
