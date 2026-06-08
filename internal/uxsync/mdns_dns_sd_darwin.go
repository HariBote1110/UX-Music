//go:build darwin

package uxsync

import (
	"context"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var (
	dnsSDBrowseLinePattern = regexp.MustCompile(`^\S+\s+Add\s+\S+\s+\S+\s+\S+\s+_uxmusic-sync\._tcp\.\s+(.+)$`)
	dnsSDLookupLinePattern = regexp.MustCompile(`can be reached at\s+(.+):(\d+)\s+\(interface\s+\d+\)`)
	dnsSDTextKeyPattern    = regexp.MustCompile(`[A-Za-z][A-Za-z0-9]*=`)
)

func discoverMDNSFallback(timeout time.Duration) ([]MDNSPeer, error) {
	if timeout <= 0 {
		timeout = 2 * time.Second
	}
	browseOutput, err := runDNSSD(timeout, "-B", MDNSServiceType, "local")
	if err != nil && strings.TrimSpace(browseOutput) == "" {
		return nil, err
	}

	instances := parseDNSSDBrowseInstances(browseOutput)
	peers := map[string]MDNSPeer{}
	lookupTimeout := timeout / 2
	if lookupTimeout < time.Second {
		lookupTimeout = time.Second
	}
	for _, instance := range instances {
		lookupOutput, err := runDNSSD(lookupTimeout, "-L", instance, MDNSServiceType, "local")
		if err != nil && strings.TrimSpace(lookupOutput) == "" {
			continue
		}
		peer, ok := parseDNSSDLookupOutput(instance, lookupOutput)
		if !ok {
			continue
		}
		key := peer.DeviceID
		if key == "" {
			key = peer.Host + ":" + peer.HostName
		}
		if existing, ok := peers[key]; ok {
			peers[key] = MergeMDNSPeers(existing, peer)
		} else {
			peers[key] = peer
		}
	}

	out := make([]MDNSPeer, 0, len(peers))
	for _, peer := range peers {
		out = append(out, peer)
	}
	return out, nil
}

func runDNSSD(timeout time.Duration, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "dns-sd", args...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func parseDNSSDBrowseInstances(output string) []string {
	instances := []string{}
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		match := dnsSDBrowseLinePattern.FindStringSubmatch(line)
		if len(match) != 2 {
			continue
		}
		instances = appendUnique(instances, strings.TrimSpace(match[1]))
	}
	return instances
}

func parseDNSSDLookupOutput(instance, output string) (MDNSPeer, bool) {
	var hostName string
	var port int
	var text []string
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		if match := dnsSDLookupLinePattern.FindStringSubmatch(line); len(match) == 3 {
			hostName = strings.TrimSuffix(strings.TrimSpace(match[1]), ".")
			parsedPort, err := strconv.Atoi(match[2])
			if err == nil {
				port = parsedPort
			}
			continue
		}
		text = append(text, parseDNSSDTextPairs(line)...)
	}
	if hostName == "" || port == 0 {
		return MDNSPeer{}, false
	}

	entry := MDNSServiceEntry{
		Instance: instance,
		HostName: hostName,
		Port:     port,
		Text:     text,
	}
	peer := NormaliseMDNSPeer(entry)
	if peer.Host == "" {
		peer.Host = hostName
	}
	if len(peer.Hosts) == 0 {
		peer.Hosts = []string{hostName}
	}
	return peer, true
}

func parseDNSSDTextPairs(line string) []string {
	matches := dnsSDTextKeyPattern.FindAllStringIndex(line, -1)
	if len(matches) == 0 {
		return nil
	}
	pairs := make([]string, 0, len(matches))
	for i, match := range matches {
		start := match[0]
		end := len(line)
		if i+1 < len(matches) {
			end = matches[i+1][0]
		}
		pair := strings.TrimSpace(line[start:end])
		if pair != "" {
			pairs = append(pairs, pair)
		}
	}
	return pairs
}
