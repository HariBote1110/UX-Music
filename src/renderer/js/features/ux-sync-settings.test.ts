import { describe, expect, it } from 'vitest';
import { formatSyncPeerEndpoint, normaliseSyncPeers } from './ux-sync-settings.js';

describe('normaliseSyncPeers', () => {
    it('keeps reachable URL and all host candidates for discovered peers', () => {
        const peers = normaliseSyncPeers([
            {
                deviceId: 'dev_mac_mini',
                displayName: 'Mac mini',
                host: '192.168.1.182',
                hosts: ['192.168.1.182', '192.168.0.226'],
                port: 8765,
                roles: ['LibraryHost', 'PlaybackTarget'],
                reachableBaseUrl: 'http://192.168.0.226:8765',
            },
        ]);

        expect(peers).toEqual([
            {
                deviceId: 'dev_mac_mini',
                displayName: 'Mac mini',
                host: '192.168.1.182',
                hosts: ['192.168.1.182', '192.168.0.226'],
                port: 8765,
                roles: ['LibraryHost', 'PlaybackTarget'],
                reachableBaseUrl: 'http://192.168.0.226:8765',
            },
        ]);
    });

    it('filters invalid peers without a device id or display name', () => {
        expect(normaliseSyncPeers([{ host: '192.168.0.2', port: 8765 }])).toEqual([]);
    });
});

describe('formatSyncPeerEndpoint', () => {
    it('prefers reachable URL when available', () => {
        expect(formatSyncPeerEndpoint({
            deviceId: 'dev',
            displayName: 'Mac mini',
            reachableBaseUrl: 'http://192.168.0.226:8765',
            host: '192.168.1.182',
            hosts: ['192.168.1.182', '192.168.0.226'],
            port: 8765,
            roles: [],
        })).toBe('http://192.168.0.226:8765');
    });

    it('falls back to host and port', () => {
        expect(formatSyncPeerEndpoint({
            deviceId: 'dev',
            displayName: 'Mac mini',
            host: '192.168.1.182',
            hosts: [],
            port: 8765,
            roles: [],
        })).toBe('http://192.168.1.182:8765');
    });
});
