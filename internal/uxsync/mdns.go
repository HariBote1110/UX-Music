package uxsync

import (
	"net"
	"strconv"
	"strings"
)

const MDNSServiceType = "_uxmusic-sync._tcp"
const MDNSDomain = "local."

type MDNSAdvertiseInfo struct {
	DeviceID        string
	DisplayName     string
	ProtocolVersion string
	Roles           []string
}

type MDNSServiceEntry struct {
	Instance string
	HostName string
	Port     int
	AddrIPv4 []string
	AddrIPv6 []string
	Text     []string
}

type MDNSPeer struct {
	DeviceID        string   `json:"deviceId"`
	DisplayName     string   `json:"displayName"`
	Host            string   `json:"host"`
	Port            int      `json:"port"`
	HostName        string   `json:"hostName"`
	ProtocolVersion string   `json:"protocolVersion"`
	Roles           []string `json:"roles"`
}

func BuildMDNSText(info MDNSAdvertiseInfo) []string {
	protocolVersion := strings.TrimSpace(info.ProtocolVersion)
	if protocolVersion == "" {
		protocolVersion = "0.1"
	}
	return []string{
		"deviceId=" + strings.TrimSpace(info.DeviceID),
		"displayName=" + strings.TrimSpace(info.DisplayName),
		"protocolVersion=" + protocolVersion,
		"roles=" + strings.Join(cleanRoles(info.Roles), ","),
	}
}

func NormaliseMDNSPeer(entry MDNSServiceEntry) MDNSPeer {
	text := map[string]string{}
	for _, item := range entry.Text {
		key, value := splitMDNSText(item)
		if key != "" {
			text[key] = value
		}
	}

	displayName := strings.TrimSpace(text["displayName"])
	if displayName == "" {
		displayName = strings.TrimSpace(entry.Instance)
	}

	return MDNSPeer{
		DeviceID:        strings.TrimSpace(text["deviceId"]),
		DisplayName:     displayName,
		Host:            preferredMDNSHost(entry),
		Port:            entry.Port,
		HostName:        strings.TrimSuffix(strings.TrimSpace(entry.HostName), "."),
		ProtocolVersion: strings.TrimSpace(text["protocolVersion"]),
		Roles:           parseRoles(text["roles"]),
	}
}

func splitMDNSText(item string) (string, string) {
	key, value, ok := strings.Cut(item, "=")
	if !ok {
		return strings.TrimSpace(item), ""
	}
	return strings.TrimSpace(key), strings.TrimSpace(value)
}

func preferredMDNSHost(entry MDNSServiceEntry) string {
	for _, host := range entry.AddrIPv4 {
		if ip := net.ParseIP(strings.TrimSpace(host)); ip != nil && ip.To4() != nil {
			return ip.String()
		}
	}
	for _, host := range entry.AddrIPv6 {
		if ip := net.ParseIP(strings.TrimSpace(host)); ip != nil {
			return ip.String()
		}
	}
	return strings.TrimSuffix(strings.TrimSpace(entry.HostName), ".")
}

func parseRoles(value string) []string {
	parts := strings.Split(value, ",")
	roles := make([]string, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part != "" {
			roles = append(roles, part)
		}
	}
	return roles
}

func cleanRoles(roles []string) []string {
	clean := make([]string, 0, len(roles))
	for _, role := range roles {
		role = strings.TrimSpace(role)
		if role != "" {
			clean = append(clean, role)
		}
	}
	return clean
}

func (p MDNSPeer) BaseURL() string {
	host := p.Host
	if strings.Contains(host, ":") && !strings.HasPrefix(host, "[") {
		host = "[" + host + "]"
	}
	return "http://" + host + ":" + strconv.Itoa(p.Port)
}
