package uxsync

import (
	"context"
	"net"
	"strings"
	"time"

	"github.com/grandcat/zeroconf"
)

type MDNSAdvertisement struct {
	server *zeroconf.Server
}

func AdvertiseMDNS(info MDNSAdvertiseInfo, port int) (*MDNSAdvertisement, error) {
	instance := strings.TrimSpace(info.DisplayName)
	if instance == "" {
		instance = "UX Music"
	}
	server, err := zeroconf.Register(
		instance,
		MDNSServiceType,
		MDNSDomain,
		port,
		BuildMDNSText(info),
		nil,
	)
	if err != nil {
		return nil, err
	}
	return &MDNSAdvertisement{server: server}, nil
}

func (a *MDNSAdvertisement) Shutdown() {
	if a == nil || a.server == nil {
		return
	}
	a.server.Shutdown()
}

func DiscoverMDNS(ctx context.Context, timeout time.Duration) ([]MDNSPeer, error) {
	if timeout <= 0 {
		timeout = 2 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	entries := make(chan *zeroconf.ServiceEntry)
	resolver, err := zeroconf.NewResolver(nil)
	if err != nil {
		return nil, err
	}
	if err := resolver.Browse(ctx, MDNSServiceType, MDNSDomain, entries); err != nil {
		return nil, err
	}

	peers := map[string]MDNSPeer{}
	for {
		select {
		case entry := <-entries:
			if entry == nil {
				continue
			}
			peer := NormaliseMDNSPeer(serviceEntryFromZeroconf(entry))
			key := peer.DeviceID
			if key == "" {
				key = peer.Host + ":" + entry.HostName
			}
			if existing, ok := peers[key]; ok {
				peers[key] = MergeMDNSPeers(existing, peer)
			} else {
				peers[key] = peer
			}
		case <-ctx.Done():
			out := make([]MDNSPeer, 0, len(peers))
			for _, peer := range peers {
				out = append(out, peer)
			}
			return out, nil
		}
	}
}

func serviceEntryFromZeroconf(entry *zeroconf.ServiceEntry) MDNSServiceEntry {
	return MDNSServiceEntry{
		Instance: entry.Instance,
		HostName: entry.HostName,
		Port:     entry.Port,
		AddrIPv4: ipsToStrings(entry.AddrIPv4),
		AddrIPv6: ipsToStrings(entry.AddrIPv6),
		Text:     entry.Text,
	}
}

func ipsToStrings(ips []net.IP) []string {
	out := make([]string, 0, len(ips))
	for _, ip := range ips {
		if ip != nil {
			out = append(out, ip.String())
		}
	}
	return out
}
