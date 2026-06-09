import { describe, expect, it } from 'vitest';
import {
    formatSyncPeerEndpoint,
    formatSyncFreeSpaceSafetyStatus,
    formatSyncPullResultSummary,
    formatSyncPushResultSummary,
    formatSyncAutoResultNotification,
    formatSyncTransferProgressSummary,
    mergeSyncPeersWithDevices,
    normaliseSyncDevices,
    normaliseSyncMinFreeSpaceGB,
    normaliseSyncAutoResult,
    normaliseSyncPairingConfirm,
    normaliseSyncPullResult,
    normaliseSyncTransferProgress,
    normaliseSyncPushResult,
    normaliseSyncPairingStart,
    normaliseSyncPeers,
    syncPeerConnectionLabel,
    syncPullActionState,
    syncPushActionState,
    syncSettingsEntryState,
    syncPeerPairingBaseUrl,
} from './ux-sync-settings.js';

describe('normaliseSyncAutoResult', () => {
    it('keeps automatic sync counters from the backend', () => {
        expect(normaliseSyncAutoResult({
            checkedDevices: 1,
            syncedDevices: 1,
            failedDevices: 0,
            pushedPlayEvents: 3,
            syncedArtwork: 1,
            pulledTracks: 2,
            skippedTracks: 5,
            paused: false,
        })).toEqual({
            checkedDevices: 1,
            syncedDevices: 1,
            failedDevices: 0,
            pushedPlayEvents: 3,
            syncedArtwork: 1,
            pulledTracks: 2,
            skippedTracks: 5,
            paused: false,
            pauseReason: '',
        });
    });
});

describe('formatSyncAutoResultNotification', () => {
    it('explains that sync ran because a paired device was reachable', () => {
        const result = normaliseSyncAutoResult({
            checkedDevices: 1,
            syncedDevices: 1,
            failedDevices: 0,
            pushedPlayEvents: 3,
            syncedArtwork: 1,
            pulledTracks: 2,
            skippedTracks: 5,
            paused: false,
        });

        expect(result && formatSyncAutoResultNotification(result)).toBe('UX Sync: 接続できたため同期しました（取得 2曲 / 既存 5曲 / 再生回数 3件 / ジャケット 1件）');
    });

    it('does not show a toast when no paired device was checked', () => {
        const result = normaliseSyncAutoResult({ checkedDevices: 0, syncedDevices: 0 });
        expect(result && formatSyncAutoResultNotification(result)).toBe('');
    });

    it('shows a pause reason when free space safety stops sync', () => {
        const result = normaliseSyncAutoResult({ paused: true, pauseReason: 'free-space-below-limit' });
        expect(result && formatSyncAutoResultNotification(result)).toBe('UX Sync: 空き容量が少ないため同期を停止しました。');
    });
});

describe('normaliseSyncMinFreeSpaceGB', () => {
    it('keeps a positive GB threshold with one decimal place', () => {
        expect(normaliseSyncMinFreeSpaceGB('5.04')).toBe(5);
        expect(normaliseSyncMinFreeSpaceGB(5.06)).toBe(5.1);
    });

    it('treats empty or negative values as disabled', () => {
        expect(normaliseSyncMinFreeSpaceGB('')).toBe(0);
        expect(normaliseSyncMinFreeSpaceGB(-1)).toBe(0);
    });
});

describe('formatSyncFreeSpaceSafetyStatus', () => {
    it('explains whether the free space safety stop is enabled', () => {
        expect(formatSyncFreeSpaceSafetyStatus(5)).toBe('空き容量が 5 GB 未満の場合は同期を停止します。');
        expect(formatSyncFreeSpaceSafetyStatus(0)).toBe('空き容量による同期停止は無効です。');
    });
});

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

describe('normaliseSyncDevices', () => {
    it('keeps paired devices without leaking their auth tokens', () => {
        expect(normaliseSyncDevices([
            {
                deviceId: 'dev_mac_mini',
                displayName: 'YukinoMac-mini',
                baseUrl: 'http://192.168.0.226:8765',
                paired: true,
                token: 'secret-token',
            },
        ])).toEqual([
            {
                deviceId: 'dev_mac_mini',
                displayName: 'YukinoMac-mini',
                baseUrl: 'http://192.168.0.226:8765',
                paired: true,
            },
        ]);
    });
});

describe('mergeSyncPeersWithDevices', () => {
    it('marks discovered peers as paired when a saved device exists', () => {
        const peers = mergeSyncPeersWithDevices(
            normaliseSyncPeers([
                {
                    deviceId: 'dev_mac_mini',
                    displayName: 'YukinoMac-mini',
                    hosts: ['192.168.0.226'],
                    port: 8765,
                    reachableBaseUrl: 'http://192.168.0.226:8765',
                },
            ]),
            normaliseSyncDevices([
                {
                    deviceId: 'dev_mac_mini',
                    displayName: 'YukinoMac-mini',
                    baseUrl: 'http://192.168.0.226:8765',
                    paired: true,
                },
            ])
        );

        expect(peers[0].paired).toBe(true);
        expect(syncPeerConnectionLabel(peers[0])).toBe('ペアリング済み');
    });

    it('keeps paired known devices as sync candidates when discovery returns nothing', () => {
        const peers = mergeSyncPeersWithDevices([], normaliseSyncDevices([
            {
                deviceId: 'dev_mac_mini',
                displayName: 'YukinoMac-mini',
                baseUrl: 'http://192.168.0.226:8765',
                paired: true,
            },
        ]));

        expect(peers).toEqual([
            {
                deviceId: 'dev_mac_mini',
                displayName: 'YukinoMac-mini',
                host: '192.168.0.226',
                hosts: ['192.168.0.226'],
                port: 8765,
                roles: [],
                reachableBaseUrl: 'http://192.168.0.226:8765',
                paired: true,
            },
        ]);
        expect(syncPeerPairingBaseUrl(peers[0])).toBe('http://192.168.0.226:8765');
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

describe('normaliseSyncPushResult', () => {
    it('keeps push counters, imported paths, and errors from the backend', () => {
        expect(normaliseSyncPushResult({
            remoteDeviceId: 'dev_mainpc',
            remoteDisplayName: 'mainPC',
            transferred: 2,
            skipped: 1,
            failed: 0,
            importedPaths: [
                'C:\\Users\\gzabu\\AppData\\Roaming\\ux-music\\SyncLibrary\\song.flac',
            ],
            errors: [],
        })).toEqual({
            remoteDeviceId: 'dev_mainpc',
            remoteDisplayName: 'mainPC',
            transferred: 2,
            skipped: 1,
            failed: 0,
            encodingMode: 'original',
            importedPaths: [
                'C:\\Users\\gzabu\\AppData\\Roaming\\ux-music\\SyncLibrary\\song.flac',
            ],
            errors: [],
        });
    });

    it('rejects malformed push responses without a remote device id', () => {
        expect(normaliseSyncPushResult({ transferred: 1 })).toBeNull();
    });
});

describe('normaliseSyncTransferProgress', () => {
    it('keeps the active file, counters, byte totals, speed, and encoding mode', () => {
        expect(normaliseSyncTransferProgress({
            direction: 'push',
            stage: 'uploading',
            trackId: 'local-track-1',
            title: 'Local Song',
            fileName: 'local.mp3',
            current: 1,
            total: 3,
            bytesDone: 1_572_864,
            bytesTotal: 3_145_728,
            bytesPerSecond: 1_572_864,
            encodingMode: 'mp3_320',
        })).toEqual({
            direction: 'push',
            stage: 'uploading',
            trackId: 'local-track-1',
            title: 'Local Song',
            fileName: 'local.mp3',
            current: 1,
            total: 3,
            bytesDone: 1_572_864,
            bytesTotal: 3_145_728,
            bytesPerSecond: 1_572_864,
            encodingMode: 'mp3_320',
        });
    });

    it('rejects malformed progress without a direction or stage', () => {
        expect(normaliseSyncTransferProgress({ fileName: 'song.flac' })).toBeNull();
    });
});

describe('formatSyncTransferProgressSummary', () => {
    it('shows the active file and transfer speed', () => {
        const progress = normaliseSyncTransferProgress({
            direction: 'push',
            stage: 'uploading',
            fileName: 'local.mp3',
            current: 1,
            total: 3,
            bytesDone: 1_572_864,
            bytesTotal: 3_145_728,
            bytesPerSecond: 1_572_864,
            encodingMode: 'mp3_320',
        });

        expect(progress && formatSyncTransferProgressSummary(progress)).toBe('転送中: local.mp3 (1 / 3) - 1.5 MB/s - MP3 320kbps');
    });

    it('uses the conversion label before upload starts', () => {
        const progress = normaliseSyncTransferProgress({
            direction: 'push',
            stage: 'transcoding',
            fileName: 'local.flac',
            current: 1,
            total: 1,
            encodingMode: 'mp3_320',
        });

        expect(progress && formatSyncTransferProgressSummary(progress)).toBe('変換中: local.flac (1 / 1) - MP3 320kbps');
    });
});

describe('syncPushActionState', () => {
    it('enables push actions when the binding and selected endpoint are available', () => {
        expect(syncPushActionState(true, 'http://192.168.0.52:8765')).toEqual({
            canPush: true,
            status: '待機中',
        });
    });

    it('disables push actions when no peer endpoint is selected', () => {
        expect(syncPushActionState(true, '')).toEqual({
            canPush: false,
            status: '転送先端末を選択してください',
        });
    });

    it('disables push actions when the Wails binding is missing', () => {
        expect(syncPushActionState(false, 'http://192.168.0.52:8765')).toEqual({
            canPush: false,
            status: 'この環境では音源転送を利用できません',
        });
    });
});

describe('formatSyncPullResultSummary', () => {
    it('summarises downloaded, skipped, and failed counters', () => {
        expect(formatSyncPullResultSummary({
            remoteDeviceId: 'dev_mac_mini',
            remoteDisplayName: 'YukinoMac-mini',
            downloaded: 2,
            skipped: 1,
            failed: 0,
            importedPaths: [],
            errors: [],
        })).toBe('YukinoMac-mini: 取得 2曲 / 既存 1曲 / 失敗 0曲');
    });

    it('falls back to the remote device id when the display name is missing', () => {
        expect(formatSyncPullResultSummary({
            remoteDeviceId: 'dev_mac_mini',
            remoteDisplayName: '',
            downloaded: 0,
            skipped: 3,
            failed: 1,
            importedPaths: [],
            errors: ['network error'],
        })).toBe('dev_mac_mini: 取得 0曲 / 既存 3曲 / 失敗 1曲');
    });
});

describe('formatSyncPushResultSummary', () => {
    it('summarises transferred, skipped, and failed counters', () => {
        expect(formatSyncPushResultSummary({
            remoteDeviceId: 'dev_mainpc',
            remoteDisplayName: 'mainPC',
            transferred: 2,
            skipped: 1,
            failed: 0,
            encodingMode: 'original',
            importedPaths: [],
            errors: [],
        })).toBe('mainPC: 転送 2曲 / 既存 1曲 / 失敗 0曲');
    });
});
