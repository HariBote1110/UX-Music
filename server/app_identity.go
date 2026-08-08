package server

import (
	"net/http"
	"os"
	"strings"
)

// identityResponse is returned by the single public GET /v1/identity endpoint,
// which unifies the former GET /wear/ping, POST /sync/identity, and
// GET /sync/schema endpoints.
type identityResponse struct {
	DeviceID                     string                  `json:"deviceId"`
	DisplayName                  string                  `json:"displayName"`
	Hostname                     string                  `json:"hostname"`
	ProtocolVersion              string                  `json:"protocolVersion"`
	MinCompatibleProtocolVersion string                  `json:"minCompatibleProtocolVersion,omitempty"`
	SchemaVersion                string                  `json:"schemaVersion,omitempty"`
	Capabilities                 []string                `json:"capabilities,omitempty"`
	Roles                        []string                `json:"roles"`
	Negotiation                  syncProtocolNegotiation `json:"negotiation,omitempty"`
	Extensions                   map[string]interface{}  `json:"extensions,omitempty"`
}

func identityHandler(w http.ResponseWriter, r *http.Request) {
	hostname := "UX Music"
	if h, err := os.Hostname(); err == nil && strings.TrimSpace(h) != "" {
		hostname = strings.TrimSpace(h)
	}
	info := syncMDNSAdvertiseInfo(ensureSyncDeviceID(), hostname)
	writeJSON(w, identityResponse{
		DeviceID:                     info.DeviceID,
		Hostname:                     hostname,
		DisplayName:                  info.DisplayName,
		ProtocolVersion:              syncProtocolVersion,
		MinCompatibleProtocolVersion: syncMinCompatibleProtocolVersion,
		SchemaVersion:                syncSchemaVersion,
		Capabilities:                 syncCapabilities(),
		Roles:                        info.Roles,
		Negotiation:                  syncNegotiationFromRequest(r),
		Extensions:                   map[string]interface{}{},
	})
}
