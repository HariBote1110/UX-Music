//go:build !darwin

package audio

import "errors"

var errProcessTapUnsupported = errors.New("process tap capture is only supported on macOS")

// ProcessTapBundleAPISupported reports bundle-ID tap support (darwin only).
func ProcessTapBundleAPISupported() bool { return false }

// WebKitHelperPIDs is unsupported outside darwin.
func WebKitHelperPIDs() ([]int, error) {
	return nil, errProcessTapUnsupported
}

// PlayProcessTap is unsupported outside darwin; it always returns an error.
func (p *Player) PlayProcessTap(targets ProcessTapTargets, gainLinear float64) error {
	return errProcessTapUnsupported
}

// StartProcessTapCapture is unsupported outside darwin; it always returns an
// error. See processtap_darwin.go for the real implementation.
func StartProcessTapCapture(targets ProcessTapTargets) (TapCapture, error) {
	return nil, errProcessTapUnsupported
}
