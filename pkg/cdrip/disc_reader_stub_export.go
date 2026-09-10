//go:build !darwin

package cdrip

// OpenNativeDisc reports that the macOS reader is unavailable.
func OpenNativeDisc() (DiscReader, error) { return openNativeDisc() }
