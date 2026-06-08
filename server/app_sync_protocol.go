package server

import (
	"net/http"
	"sort"
	"strings"
)

const syncProtocolName = "ux-music-sync"
const syncProtocolVersion = "0.2"
const syncMinCompatibleProtocolVersion = "0.1"
const syncSchemaVersion = "2026-06-09"
const syncProtocolVersionHeader = "X-UX-Music-Sync-Protocol-Version"
const syncSchemaVersionHeader = "X-UX-Music-Sync-Schema-Version"
const syncCapabilitiesHeader = "X-UX-Music-Sync-Capabilities"

var syncProtocolCapabilities = []string{
	"identity.v1",
	"schema.v1",
	"discovery.mdns.v1",
	"pairing.code.v1",
	"library.events.v1",
	"library.snapshot.v1",
	"library.asset-file.v1",
	"library.import.v1",
	"library.transfer-progress.v1",
	"library.transcode.mp3-320.v1",
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

type syncProtocolSchemaDocument struct {
	Protocol                     string                               `json:"protocol"`
	ProtocolVersion              string                               `json:"protocolVersion"`
	MinCompatibleProtocolVersion string                               `json:"minCompatibleProtocolVersion"`
	SchemaVersion                string                               `json:"schemaVersion"`
	Capabilities                 []string                             `json:"capabilities"`
	Extensibility                syncProtocolExtensibility            `json:"extensibility"`
	Messages                     map[string]syncProtocolMessageSchema `json:"messages"`
	Endpoints                    []syncProtocolEndpointSchema         `json:"endpoints"`
}

type syncProtocolExtensibility struct {
	UnknownFields       string `json:"unknownFields"`
	UnknownCapabilities string `json:"unknownCapabilities"`
	ExtensionsField     string `json:"extensionsField"`
}

type syncProtocolMessageSchema struct {
	Required []string `json:"required"`
	Optional []string `json:"optional"`
}

type syncProtocolEndpointSchema struct {
	Method       string   `json:"method"`
	Path         string   `json:"path"`
	Auth         string   `json:"auth"`
	Capability   string   `json:"capability"`
	RequestType  string   `json:"requestType,omitempty"`
	ResponseType string   `json:"responseType"`
	Notes        []string `json:"notes,omitempty"`
}

func syncSchemaHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method Not Allowed", http.StatusMethodNotAllowed)
		return
	}
	writeJSON(w, buildSyncProtocolSchemaDocument())
}

func buildSyncProtocolSchemaDocument() syncProtocolSchemaDocument {
	return syncProtocolSchemaDocument{
		Protocol:                     syncProtocolName,
		ProtocolVersion:              syncProtocolVersion,
		MinCompatibleProtocolVersion: syncMinCompatibleProtocolVersion,
		SchemaVersion:                syncSchemaVersion,
		Capabilities:                 syncCapabilities(),
		Extensibility: syncProtocolExtensibility{
			UnknownFields:       "ignore",
			UnknownCapabilities: "preserve",
			ExtensionsField:     "extensions",
		},
		Messages: map[string]syncProtocolMessageSchema{
			"SyncIdentity": {
				Required: []string{"deviceId", "displayName", "protocolVersion", "schemaVersion", "capabilities"},
				Optional: []string{"hostname", "roles", "negotiation", "extensions"},
			},
			"SyncLibrarySnapshot": {
				Required: []string{"deviceId", "displayName", "count", "tracks", "generatedAt"},
				Optional: []string{"extensions"},
			},
			"SyncLibraryImport": {
				Required: []string{"sourceDeviceId", "track", "file"},
				Optional: []string{"sourceDisplayName", "syncTransferEncoding", "audioBitrateKbps", "extensions"},
			},
			"SyncTransferProgress": {
				Required: []string{"direction", "stage", "current", "total", "encodingMode"},
				Optional: []string{"trackId", "title", "fileName", "bytesDone", "bytesTotal", "bytesPerSecond", "updatedAt", "extensions"},
			},
			"SyncPlayEvents": {
				Required: []string{"deviceId", "playEvents"},
				Optional: []string{"extensions"},
			},
		},
		Endpoints: []syncProtocolEndpointSchema{
			{Method: http.MethodGet, Path: "/sync/identity", Auth: "public", Capability: "identity.v1", ResponseType: "SyncIdentity"},
			{Method: http.MethodGet, Path: "/sync/schema", Auth: "public", Capability: "schema.v1", ResponseType: "SyncProtocolSchema"},
			{Method: http.MethodPost, Path: "/sync/pairing/start", Auth: "public", Capability: "pairing.code.v1", RequestType: "SyncPairingStartRequest", ResponseType: "SyncPairingStartResponse"},
			{Method: http.MethodPost, Path: "/sync/pairing/confirm", Auth: "public", Capability: "pairing.code.v1", RequestType: "SyncPairingConfirmRequest", ResponseType: "SyncPairingConfirmResponse"},
			{Method: http.MethodGet, Path: "/sync/library/snapshot", Auth: "sync-token", Capability: "library.snapshot.v1", ResponseType: "SyncLibrarySnapshot"},
			{Method: http.MethodGet, Path: "/sync/assets/{trackId}/file", Auth: "sync-token", Capability: "library.asset-file.v1", ResponseType: "binary"},
			{Method: http.MethodPost, Path: "/sync/library/import", Auth: "sync-token", Capability: "library.import.v1", RequestType: "multipart", ResponseType: "SyncLibraryImportResponse", Notes: []string{"client may send original audio or mp3_320 when library.transcode.mp3-320.v1 is supported"}},
			{Method: http.MethodPost, Path: "/sync/library/events", Auth: "sync-token", Capability: "library.events.v1", RequestType: "SyncPlayEvents", ResponseType: "SyncPlayEventsAck"},
		},
	}
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
