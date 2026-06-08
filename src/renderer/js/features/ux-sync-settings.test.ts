import { describe, expect, it } from 'vitest';
import {
    formatSyncPeerEndpoint,
    normaliseSyncPairingConfirm,
    normaliseSyncPullResult,
    normaliseSyncPairingStart,
    normaliseSyncPeers,
    syncPullActionState,
    syncSettingsEntryState,
    syncPeerPairingBaseUrl,
} from './ux-sync-settings.js';

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

describe('syncPeerPairingBaseUrl', () => {
    it('uses the probed reachable URL for pairing', () => {
        expect(syncPeerPairingBaseUrl({
            deviceId: 'dev',
            displayName: 'mainPC',
            reachableBaseUrl: 'http://mainPC.local:8765',
            host: '192.168.1.182',
            hosts: ['192.168.1.182'],
            port: 8765,
            roles: [],
        })).toBe('http://mainPC.local:8765');
    });

    it('falls back to the formatted host endpoint when probing has not selected one', () => {
        expect(syncPeerPairingBaseUrl({
            deviceId: 'dev',
            displayName: 'mainPC',
            host: '192.168.0.52',
            hosts: [],
            port: 8765,
            roles: [],
        })).toBe('http://192.168.0.52:8765');
    });

    it('returns an empty string when the peer cannot be addressed', () => {
        expect(syncPeerPairingBaseUrl({
            deviceId: 'dev',
            displayName: 'mainPC',
            hosts: [],
            roles: [],
        })).toBe('');
    });
});

describe('normaliseSyncPairingStart', () => {
    it('keeps the session and six digit code returned by the backend', () => {
        expect(normaliseSyncPairingStart({
            baseUrl: 'http://mainPC.local:8765',
            sessionId: 'sess_remote_1',
            localDeviceId: 'dev_local',
            remoteDeviceId: 'dev_remote',
            remoteDisplayName: 'mainPC',
            code: '123456',
            expiresAt: '2026-06-08T12:02:00Z',
        })).toEqual({
            baseUrl: 'http://mainPC.local:8765',
            sessionId: 'sess_remote_1',
            localDeviceId: 'dev_local',
            remoteDeviceId: 'dev_remote',
            remoteDisplayName: 'mainPC',
            code: '123456',
            expiresAt: '2026-06-08T12:02:00Z',
        });
    });

    it('rejects malformed pairing start responses', () => {
        expect(normaliseSyncPairingStart({ sessionId: 'sess_remote_1', code: '123456' })).toBeNull();
    });
});

describe('normaliseSyncPairingConfirm', () => {
    it('keeps the remote device identity and saved state', () => {
        expect(normaliseSyncPairingConfirm({
            remoteDeviceId: 'dev_remote',
            remoteDisplayName: 'mainPC',
            tokenSaved: true,
        })).toEqual({
            remoteDeviceId: 'dev_remote',
            remoteDisplayName: 'mainPC',
            tokenSaved: true,
        });
    });
});

describe('syncSettingsEntryState', () => {
    it('shows the dedicated sync settings entry when Wails sync bindings are available', () => {
        expect(syncSettingsEntryState(true)).toEqual({
            visible: true,
            canOpen: true,
            status: '利用可能',
        });
    });

    it('hides the entry outside the Wails sync runtime', () => {
        expect(syncSettingsEntryState(false)).toEqual({
            visible: false,
            canOpen: false,
            status: 'この環境では利用できません',
        });
    });
});

describe('normaliseSyncPullResult', () => {
    it('keeps pull counters, imported paths, and errors from the backend', () => {
        expect(normaliseSyncPullResult({
            remoteDeviceId: 'dev_mac_mini',
            remoteDisplayName: 'YukinoMac-mini',
            downloaded: 2,
            skipped: 1,
            failed: 0,
            importedPaths: [
                'C:\\Users\\gzabu\\AppData\\Roaming\\ux-music\\SyncLibrary\\song.flac',
            ],
            errors: [],
        })).toEqual({
            remoteDeviceId: 'dev_mac_mini',
            remoteDisplayName: 'YukinoMac-mini',
            downloaded: 2,
            skipped: 1,
            failed: 0,
            importedPaths: [
                'C:\\Users\\gzabu\\AppData\\Roaming\\ux-music\\SyncLibrary\\song.flac',
            ],
            errors: [],
        });
    });

    it('rejects malformed pull responses without a remote device id', () => {
        expect(normaliseSyncPullResult({ downloaded: 1 })).toBeNull();
    });
});

describe('syncPullActionState', () => {
    it('enables pull actions when the binding and selected endpoint are available', () => {
        expect(syncPullActionState(true, 'http://192.168.0.226:8765')).toEqual({
            canPull: true,
            status: '待機中',
        });
    });

    it('disables pull actions when no peer endpoint is selected', () => {
        expect(syncPullActionState(true, '')).toEqual({
            canPull: false,
            status: '同期元端末を選択してください',
        });
    });

    it('disables pull actions when the Wails binding is missing', () => {
        expect(syncPullActionState(false, 'http://192.168.0.226:8765')).toEqual({
            canPull: false,
            status: 'この環境では音源取得を利用できません',
        });
    });
});
