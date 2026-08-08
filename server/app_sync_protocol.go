package server

import (
	"net/http"
	"sort"
	"strings"
)

const syncProtocolName = "ux-music-sync"
const syncProtocolVersion = "1.0"
const syncMinCompatibleProtocolVersion = "1.0"
const syncSchemaVersion = "2026-06-09"
const syncProtocolVersionHeader = "X-UX-Music-Sync-Protocol-Version"
const syncSchemaVersionHeader = "X-UX-Music-Sync-Schema-Version"
const syncCapabilitiesHeader = "X-UX-Music-Sync-Capabilities"

var syncProtocolCapabilities = []string{
	"identity.v1",
	"discovery.mdns.v1",
	"pairing.code.v1",
	"pairing.redeem.v1",
	"library.events.v1",
	"library.snapshot.v1",
	"library.asset-file.v1",
	"library.artwork.v1",
	"library.import.v1",
	"library.storage-safety.v1",
	"library.transfer-progress.v1",
	"library.transcode.mp3-320.v1",
	"library.auto-sync.v1",
}

type syncProtocolNegotiation struct {
	RequestedProtocolVersion string   `json:"requestedProtocolVersion,omitempty"`
	RequestedSchemaVersion   string   `json:"requestedSchemaVersion,omitempty"`
	RequestedCapabilities    []string `json:"requestedCapabilities,omitempty"`
	SelectedProtocolVersion  string   `json:"selectedProtocolVersion"`
	SelectedSchemaVersion    string   `json:"selectedSchemaVersion"`
	AcceptedCapabilities     []string `json:"acceptedCapabilities"`
	Compatible               bool     `json:"compatible"`
	Warnings                 []string `json:"warnings,omitempty"`
}

func syncNegotiationFromRequest(r *http.Request) syncProtocolNegotiation {
	requestedVersion := ""
	requestedSchema := ""
	var requestedCapabilities []string
	if r != nil {
		requestedVersion = strings.TrimSpace(r.Header.Get(syncProtocolVersionHeader))
		requestedSchema = strings.TrimSpace(r.Header.Get(syncSchemaVersionHeader))
		requestedCapabilities = parseCSVTokens(r.Header.Get(syncCapabilitiesHeader))
	}
	accepted := intersectStrings(requestedCapabilities, syncProtocolCapabilities)
	compatible := syncProtocolVersionsCompatible(requestedVersion, syncProtocolVersion)
	warnings := []string{}
	if requestedVersion != "" && !compatible {
		warnings = append(warnings, "protocol major version differs")
	}
	if len(requestedCapabilities) > 0 && len(accepted) == 0 {
		warnings = append(warnings, "no shared requested capabilities")
	}
	return syncProtocolNegotiation{
		RequestedProtocolVersion: requestedVersion,
		RequestedSchemaVersion:   requestedSchema,
		RequestedCapabilities:    requestedCapabilities,
		SelectedProtocolVersion:  syncProtocolVersion,
		SelectedSchemaVersion:    syncSchemaVersion,
		AcceptedCapabilities:     accepted,
		Compatible:               compatible,
		Warnings:                 warnings,
	}
}

func syncProtocolVersionsCompatible(requested, current string) bool {
	requested = strings.TrimSpace(requested)
	if requested == "" {
		return true
	}
	return protocolMajor(requested) == protocolMajor(current)
}

func protocolMajor(version string) string {
	major, _, _ := strings.Cut(strings.TrimSpace(version), ".")
	return major
}

func syncCapabilities() []string {
	return append([]string{}, syncProtocolCapabilities...)
}

func syncCapabilitiesCSV() string {
	return strings.Join(syncCapabilities(), ",")
}

func parseCSVTokens(value string) []string {
	parts := strings.Split(value, ",")
	tokens := make([]string, 0, len(parts))
	seen := map[string]bool{}
	for _, part := range parts {
		token := strings.TrimSpace(part)
		if token == "" || seen[token] {
			continue
		}
		seen[token] = true
		tokens = append(tokens, token)
	}
	return tokens
}

func containsCSVToken(value, token string) bool {
	for _, item := range parseCSVTokens(value) {
		if item == token {
			return true
		}
	}
	return false
}

func stringSliceContains(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func intersectStrings(requested, available []string) []string {
	if len(requested) == 0 {
		return syncCapabilities()
	}
	availableSet := map[string]bool{}
	for _, item := range available {
		availableSet[item] = true
	}
	var shared []string
	seen := map[string]bool{}
	for _, item := range requested {
		if !availableSet[item] || seen[item] {
			continue
		}
		seen[item] = true
		shared = append(shared, item)
	}
	sort.Strings(shared)
	return shared
}
