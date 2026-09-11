package uxsync

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"
)

func ResolveReachablePeer(peer MDNSPeer, client *http.Client) (MDNSPeer, error) {
	if client == nil {
		client = &http.Client{Timeout: 600 * time.Millisecond}
	}
	candidates := peer.CandidateBaseURLs()
	storedCount := len(peer.candidateBaseURLsForPort(peer.Port))
	if storedCount > len(candidates) {
		storedCount = len(candidates)
	}
	var lastErr error
	if storedCount > 0 {
		// The stored address keeps the pre-port-hopping acceptance rule: a
		// successful identity endpoint is enough, regardless of its device ID.
		if baseURL, err := probeReachabilityCandidates(client, candidates[:storedCount], "", false); err == nil {
			peer.ReachableBaseURL = baseURL
			return peer, nil
		} else {
			lastErr = err
		}
	}
	if strings.TrimSpace(peer.DeviceID) == "" {
		if lastErr != nil {
			return peer, lastErr
		}
		return peer, fmt.Errorf("sync peer has no stored candidate address")
	}
	if storedCount == len(candidates) {
		if lastErr != nil {
			return peer, lastErr
		}
		return peer, fmt.Errorf("sync peer has no candidate addresses")
	}
	baseURL, err := probeReachabilityCandidates(client, candidates[storedCount:], peer.DeviceID, true)
	if err == nil {
		peer.ReachableBaseURL = baseURL
		return peer, nil
	}
	if lastErr != nil {
		return peer, fmt.Errorf("stored candidate failed: %v; fallback candidates failed: %w", lastErr, err)
	}
	if len(candidates) > storedCount {
		return peer, err
	}
	return peer, fmt.Errorf("sync peer has no candidate addresses")
}

func ResolveReachablePeers(peers []MDNSPeer, client *http.Client) []MDNSPeer {
	resolved := make([]MDNSPeer, len(peers))
	var wg sync.WaitGroup
	for index, peer := range peers {
		resolved[index] = peer
		wg.Add(1)
		go func(index int, peer MDNSPeer) {
			defer wg.Done()
			if next, err := ResolveReachablePeer(peer, client); err == nil {
				resolved[index] = next
			}
		}(index, peer)
	}
	wg.Wait()
	return resolved
}

func probeSyncIdentity(client *http.Client, baseURL string) error {
	return probeSyncIdentityForPeer(client, baseURL, "")
}

func probeSyncIdentityForPeer(client *http.Client, baseURL, expectedDeviceID string) error {
	ctx, cancel := context.WithTimeout(context.Background(), clientTimeout(client))
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"/v1/identity", nil)
	if err != nil {
		return err
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("sync identity probe returned %d", resp.StatusCode)
	}
	if expectedDeviceID == "" {
		return nil
	}
	var identity struct {
		DeviceID string `json:"deviceId"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&identity); err != nil {
		return fmt.Errorf("decode sync identity: %w", err)
	}
	if identity.DeviceID != expectedDeviceID {
		return fmt.Errorf("sync identity device id mismatch: expected %q, got %q", expectedDeviceID, identity.DeviceID)
	}
	return nil
}

func probeReachabilityCandidates(client *http.Client, candidates []string, expectedDeviceID string, requireDeviceID bool) (string, error) {
	if len(candidates) == 0 {
		return "", fmt.Errorf("sync peer has no candidate addresses")
	}
	type result struct {
		index int
		err   error
	}
	results := make(chan result, len(candidates))
	var wg sync.WaitGroup
	for index, baseURL := range candidates {
		wg.Add(1)
		go func(index int, baseURL string) {
			defer wg.Done()
			probe := probeSyncIdentity
			if requireDeviceID {
				probe = func(client *http.Client, baseURL string) error {
					return probeSyncIdentityForPeer(client, baseURL, expectedDeviceID)
				}
			}
			results <- result{index: index, err: probe(client, baseURL)}
		}(index, baseURL)
	}
	wg.Wait()
	close(results)

	errs := make([]error, len(candidates))
	for item := range results {
		errs[item.index] = item.err
	}
	for index, err := range errs {
		if err == nil {
			return candidates[index], nil
		}
	}
	return "", errs[len(errs)-1]
}

func clientTimeout(client *http.Client) time.Duration {
	if client.Timeout > 0 {
		return client.Timeout
	}
	return 600 * time.Millisecond
}
