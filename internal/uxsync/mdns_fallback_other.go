//go:build !darwin

package uxsync

import "time"

func discoverMDNSFallback(timeout time.Duration) ([]MDNSPeer, error) {
	return nil, nil
}
