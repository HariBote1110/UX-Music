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
	Hosts           []string `json:"hosts"`
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
		Hosts:           mdnsHosts(entry),
		Port:            entry.Port,
		HostName:        strings.TrimSuffix(strings.TrimSpace(entry.HostName), "."),
		ProtocolVersion: strings.TrimSpace(text["protocolVersion"]),
		Roles:           parseRoles(text["roles"]),
	}
}

func MergeMDNSPeers(existing, incoming MDNSPeer) MDNSPeer {
	merged := existing
	if merged.DeviceID == "" {
		merged.DeviceID = incoming.DeviceID
	}
	if merged.DisplayName == "" {
		merged.DisplayName = incoming.DisplayName
	}
	if merged.Host == "" {
		merged.Host = incoming.Host
	}
	if merged.Port == 0 {
		merged.Port = incoming.Port
	}
	if merged.HostName == "" {
		merged.HostName = incoming.HostName
	}
	if merged.ProtocolVersion == "" {
		merged.ProtocolVersion = incoming.ProtocolVersion
	}
	merged.Hosts = appendUnique(merged.Hosts, incoming.Hosts...)
	if incoming.Host != "" {
		merged.Hosts = appendUnique(merged.Hosts, incoming.Host)
	}
	merged.Roles = appendUnique(merged.Roles, incoming.Roles...)
	return merged
}

func splitMDNSText(item string) (string, string) {
	key, value, ok := strings.Cut(item, "=")
	if !ok {
		return strings.TrimSpace(item), ""
	}
	return strings.TrimSpace(key), strings.TrimSpace(value)
}

func preferredMDNSHost(entry MDNSServiceEntry) string {
	for _, host := range mdnsHosts(entry) {
		if ip := net.ParseIP(strings.TrimSpace(host)); ip != nil && ip.To4() != nil {
			return ip.String()
		}
	}
	for _, host := range mdnsHosts(entry) {
		if ip := net.ParseIP(strings.TrimSpace(host)); ip != nil {
			return ip.String()
		}
	}
	return strings.TrimSuffix(strings.TrimSpace(entry.HostName), ".")
}

func mdnsHosts(entry MDNSServiceEntry) []string {
	hosts := make([]string, 0, len(entry.AddrIPv4)+len(entry.AddrIPv6))
	for _, host := range entry.AddrIPv4 {
		if ip := net.ParseIP(strings.TrimSpace(host)); ip != nil {
			hosts = appendUnique(hosts, ip.String())
		}
	}
	for _, host := range entry.AddrIPv6 {
		if ip := net.ParseIP(strings.TrimSpace(host)); ip != nil {
			hosts = appendUnique(hosts, ip.String())
		}
	}
	return hosts
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

func appendUnique(values []string, additions ...string) []string {
	seen := map[string]bool{}
	out := make([]string, 0, len(values)+len(additions))
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value != "" && !seen[value] {
			seen[value] = true
			out = append(out, value)
		}
	}
	for _, value := range additions {
		value = strings.TrimSpace(value)
		if value != "" && !seen[value] {
			seen[value] = true
			out = append(out, value)
		}
	}
	return out
}

func (p MDNSPeer) BaseURL() string {
	host := p.Host
	if strings.Contains(host, ":") && !strings.HasPrefix(host, "[") {
		host = "[" + host + "]"
	}
	return "http://" + host + ":" + strconv.Itoa(p.Port)
}
