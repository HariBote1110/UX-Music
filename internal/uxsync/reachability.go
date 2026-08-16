package uxsync

import (
	"context"
	"fmt"
	"net/http"
	"time"
)

func ResolveReachablePeer(peer MDNSPeer, client *http.Client) (MDNSPeer, error) {
	if client == nil {
		client = &http.Client{Timeout: 600 * time.Millisecond}
	}
	var lastErr error
	for _, baseURL := range peer.CandidateBaseURLs() {
		if err := probeSyncIdentity(client, baseURL); err != nil {
			lastErr = err
			continue
		}
		peer.ReachableBaseURL = baseURL
		return peer, nil
	}
	if lastErr != nil {
		return peer, lastErr
	}
	return peer, fmt.Errorf("sync peer has no candidate addresses")
}

func ResolveReachablePeers(peers []MDNSPeer, client *http.Client) []MDNSPeer {
	resolved := make([]MDNSPeer, 0, len(peers))
	for _, peer := range peers {
		next, err := ResolveReachablePeer(peer, client)
		if err == nil {
			resolved = append(resolved, next)
			continue
		}
		resolved = append(resolved, peer)
	}
	return resolved
}

func probeSyncIdentity(client *http.Client, baseURL string) error {
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
	return nil
}

func clientTimeout(client *http.Client) time.Duration {
	if client.Timeout > 0 {
		return client.Timeout
	}
	return 600 * time.Millisecond
}
