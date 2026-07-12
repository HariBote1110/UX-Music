//go:build !darwin

package audio

import "errors"

var errProcessTapUnsupported = errors.New("process tap capture is only supported on macOS")

// ProcessTapBundleAPISupported reports bundle-ID tap support (darwin only).
func ProcessTapBundleAPISupported() bool { return false }

// PlayProcessTap is unsupported outside darwin; it always returns an error.
func (p *Player) PlayProcessTap(targets ProcessTapTargets, gainLinear float64) error {
	return errProcessTapUnsupported
}
