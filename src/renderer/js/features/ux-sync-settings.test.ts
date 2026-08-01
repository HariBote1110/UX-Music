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
    syncCachePolicyOptions,
    normaliseSyncCachePolicy,
    syncPreferredFormatOptions,
    normaliseSyncPreferredFormat,
    syncSettingsEntryState,
    syncPeerPairingBaseUrl,
    manualSyncPeerBaseUrl,
    startManualSyncPairing,
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

    // 異常系: バックエンドが壊れた値を返してもカウンタは 0 以上の整数に矯正される
    it('coerces negative counters to zero', () => {
        expect(normaliseSyncAutoResult({
            checkedDevices: -1,
            syncedDevices: -5,
            failedDevices: -0.5,
            pushedPlayEvents: -100,
            syncedArtwork: -1,
            pulledTracks: -2,
            skippedTracks: -3,
            paused: false,
        })).toEqual({
            checkedDevices: 0,
            syncedDevices: 0,
            failedDevices: 0,
            pushedPlayEvents: 0,
            syncedArtwork: 0,
            pulledTracks: 0,
            skippedTracks: 0,
            paused: false,
            pauseReason: '',
        });
    });

    it('coerces NaN and Infinity counters to zero', () => {
        expect(normaliseSyncAutoResult({
            checkedDevices: Number.NaN,
            syncedDevices: Number.POSITIVE_INFINITY,
            failedDevices: Number.NEGATIVE_INFINITY,
            pushedPlayEvents: Number.NaN,
            syncedArtwork: Number.POSITIVE_INFINITY,
            pulledTracks: Number.NaN,
            skippedTracks: Number.NEGATIVE_INFINITY,
        })).toEqual({
            checkedDevices: 0,
            syncedDevices: 0,
            failedDevices: 0,
            pushedPlayEvents: 0,
            syncedArtwork: 0,
            pulledTracks: 0,
            skippedTracks: 0,
            paused: false,
            pauseReason: '',
        });
    });

    // 曲数は整数で表示するため小数は切り捨てる
    it('floors fractional counters', () => {
        expect(normaliseSyncAutoResult({
            checkedDevices: 1.9,
            syncedDevices: 2.5,
            failedDevices: 0.9,
            pushedPlayEvents: 3.99,
            syncedArtwork: 1.01,
            pulledTracks: 2.7,
            skippedTracks: 5.5,
        })).toEqual({
            checkedDevices: 1,
            syncedDevices: 2,
            failedDevices: 0,
            pushedPlayEvents: 3,
            syncedArtwork: 1,
            pulledTracks: 2,
            skippedTracks: 5,
            paused: false,
            pauseReason: '',
        });
    });

    it('coerces string, boolean, object, and nullish counters to zero', () => {
        expect(normaliseSyncAutoResult({
            checkedDevices: '5',
            syncedDevices: true,
            failedDevices: null,
            pushedPlayEvents: undefined,
            syncedArtwork: {},
            pulledTracks: [],
            skippedTracks: '12',
        })).toEqual({
            checkedDevices: 0,
            syncedDevices: 0,
            failedDevices: 0,
            pushedPlayEvents: 0,
            syncedArtwork: 0,
            pulledTracks: 0,
            skippedTracks: 0,
            paused: false,
            pauseReason: '',
        });
    });

    // 停止理由は前後の空白を落としてから比較に使われる
    it('trims whitespace around the pause reason', () => {
        expect(normaliseSyncAutoResult({ paused: true, pauseReason: '  free-space-below-limit  ' })?.pauseReason)
            .toBe('free-space-below-limit');
        expect(normaliseSyncAutoResult({ paused: true, pauseReason: '\tmanual-stop\n' })?.pauseReason)
            .toBe('manual-stop');
    });

    it('coerces a non-string pause reason to an empty string', () => {
        expect(normaliseSyncAutoResult({ paused: true, pauseReason: 42 })?.pauseReason).toBe('');
        expect(normaliseSyncAutoResult({ paused: true, pauseReason: { reason: 'x' } })?.pauseReason).toBe('');
        expect(normaliseSyncAutoResult({ paused: true, pauseReason: true })?.pauseReason).toBe('');
        expect(normaliseSyncAutoResult({ paused: true, pauseReason: ['x'] })?.pauseReason).toBe('');
    });

    it('coerces null, undefined, and missing pause reasons to an empty string', () => {
        expect(normaliseSyncAutoResult({ paused: true, pauseReason: null })?.pauseReason).toBe('');
        expect(normaliseSyncAutoResult({ paused: true, pauseReason: undefined })?.pauseReason).toBe('');
        expect(normaliseSyncAutoResult({ paused: true })?.pauseReason).toBe('');
    });

    it('treats a truthy but non-boolean paused flag as not paused', () => {
        expect(normaliseSyncAutoResult({ paused: 'true' })?.paused).toBe(false);
        expect(normaliseSyncAutoResult({ paused: 1 })?.paused).toBe(false);
    });

    it('rejects non-object auto sync payloads', () => {
        expect(normaliseSyncAutoResult(null)).toBeNull();
        expect(normaliseSyncAutoResult(undefined)).toBeNull();
        expect(normaliseSyncAutoResult('paused')).toBeNull();
        expect(normaliseSyncAutoResult(42)).toBeNull();
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

    it('stays silent when only already-present tracks were skipped (no new data)', () => {
        const result = normaliseSyncAutoResult({
            checkedDevices: 1,
            syncedDevices: 1,
            pulledTracks: 0,
            pushedPlayEvents: 0,
            syncedArtwork: 0,
            skippedTracks: 12,
            paused: false,
        });
        expect(result && formatSyncAutoResultNotification(result)).toBe('');
    });

    it('stays silent when a device was merely confirmed with nothing to do', () => {
        const result = normaliseSyncAutoResult({ checkedDevices: 1, syncedDevices: 1 });
        expect(result && formatSyncAutoResultNotification(result)).toBe('');
    });

    it('still notifies when new data actually moved, including skipped count', () => {
        const result = normaliseSyncAutoResult({
            checkedDevices: 1,
            syncedDevices: 1,
            pulledTracks: 2,
            skippedTracks: 5,
        });
        expect(result && formatSyncAutoResultNotification(result)).toBe('UX Sync: 接続できたため同期しました（取得 2曲 / 既存 5曲）');
    });

    // 異常系: 小数のカウンタが来ても通知本文には整数だけが並ぶ
    it('reports floored counters when the backend sends fractional values', () => {
        const result = normaliseSyncAutoResult({
            checkedDevices: 1.9,
            syncedDevices: 1,
            pulledTracks: 3.7,
            skippedTracks: 5.2,
            pushedPlayEvents: 2.9,
            syncedArtwork: 1.4,
        });
        expect(result && formatSyncAutoResultNotification(result)).toBe('UX Sync: 接続できたため同期しました（取得 3曲 / 既存 5曲 / 再生回数 2件 / ジャケット 1件）');
    });

    it('matches the free space pause reason even when it arrives padded with whitespace', () => {
        const result = normaliseSyncAutoResult({ paused: true, pauseReason: '  free-space-below-limit\n' });
        expect(result && formatSyncAutoResultNotification(result)).toBe('UX Sync: 空き容量が少ないため同期を停止しました。');
    });

    it('falls back to the generic pause message when the reason is not a string', () => {
        const result = normaliseSyncAutoResult({ paused: true, pauseReason: 42 });
        expect(result && formatSyncAutoResultNotification(result)).toBe('UX Sync: 自動同期を停止しました。');
    });

    it('stays silent when every counter arrives as an unusable string', () => {
        const result = normaliseSyncAutoResult({ checkedDevices: '3', pulledTracks: '2', pushedPlayEvents: '1' });
        expect(result && formatSyncAutoResultNotification(result)).toBe('');
    });

    it('stays silent when the counters are negative', () => {
        const result = normaliseSyncAutoResult({ checkedDevices: 2, pulledTracks: -5, pushedPlayEvents: -1, syncedArtwork: -1 });
        expect(result && formatSyncAutoResultNotification(result)).toBe('');
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

    // 異常系: 数値化できない値や非有限値はしきい値無効として扱う
    it('treats unparsable, non-finite, and nullish thresholds as disabled', () => {
        expect(normaliseSyncMinFreeSpaceGB('abc')).toBe(0);
        expect(normaliseSyncMinFreeSpaceGB(Number.NaN)).toBe(0);
        expect(normaliseSyncMinFreeSpaceGB(Number.POSITIVE_INFINITY)).toBe(0);
        expect(normaliseSyncMinFreeSpaceGB(Number.NEGATIVE_INFINITY)).toBe(0);
        expect(normaliseSyncMinFreeSpaceGB(null)).toBe(0);
        expect(normaliseSyncMinFreeSpaceGB(undefined)).toBe(0);
        expect(normaliseSyncMinFreeSpaceGB({})).toBe(0);
        expect(normaliseSyncMinFreeSpaceGB(['5'])).toBe(5);
    });

    it('clamps oversized thresholds to 1024 GB', () => {
        expect(normaliseSyncMinFreeSpaceGB(99999)).toBe(1024);
        expect(normaliseSyncMinFreeSpaceGB('4096')).toBe(1024);
        expect(normaliseSyncMinFreeSpaceGB(1024.4)).toBe(1024);
    });
});

describe('formatSyncFreeSpaceSafetyStatus', () => {
    it('explains whether the free space safety stop is enabled', () => {
        expect(formatSyncFreeSpaceSafetyStatus(5)).toBe('空き容量が 5 GB 未満の場合は同期を停止します。');
        expect(formatSyncFreeSpaceSafetyStatus(0)).toBe('空き容量による同期停止は無効です。');
    });
});

describe('normaliseSyncCachePolicy', () => {
    it('keeps selective and defaults unknown values to mirror', () => {
        expect(normaliseSyncCachePolicy('selective')).toBe('selective');
        expect(normaliseSyncCachePolicy('mirror')).toBe('mirror');
        expect(normaliseSyncCachePolicy('')).toBe('mirror');
        expect(normaliseSyncCachePolicy('future')).toBe('mirror');
    });
});

describe('syncCachePolicyOptions', () => {
    it('offers mirror and selective cache policies for the storage tab', () => {
        expect(syncCachePolicyOptions()).toEqual([
            { value: 'mirror', label: '全曲ミラー' },
            { value: 'selective', label: '最近再生＋キュー先読み' },
        ]);
    });
});

describe('normaliseSyncPreferredFormat', () => {
    it('keeps mp3_320 and defaults unknown values to original', () => {
        expect(normaliseSyncPreferredFormat('mp3_320')).toBe('mp3_320');
        expect(normaliseSyncPreferredFormat('original')).toBe('original');
        expect(normaliseSyncPreferredFormat('')).toBe('original');
        expect(normaliseSyncPreferredFormat('future')).toBe('original');
    });
});

describe('syncPreferredFormatOptions', () => {
    it('offers original and MP3 320kbps for the storage tab', () => {
        expect(syncPreferredFormatOptions()).toEqual([
            { value: 'original', label: '原本' },
            { value: 'mp3_320', label: 'MP3 320kbps' },
        ]);
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

    // 異常系: mDNS 応答の前後空白は落としてから保持する
    it('trims whitespace from peer identity, host, and endpoint strings', () => {
        expect(normaliseSyncPeers([
            {
                deviceId: '  dev_mac_mini  ',
                displayName: '\tMac mini\n',
                host: '  192.168.1.182  ',
                hosts: ['  192.168.1.182  ', ' 192.168.0.226 '],
                port: 8765,
                roles: ['  LibraryHost  ', ' PlaybackTarget '],
                reachableBaseUrl: '  http://192.168.0.226:8765  ',
            },
        ])).toEqual([
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

    it('drops peers whose device id or display name is only whitespace', () => {
        expect(normaliseSyncPeers([
            { deviceId: '   ', displayName: 'Mac mini' },
            { deviceId: 'dev_a', displayName: '  ' },
            { deviceId: '\t\n', displayName: '\t\n' },
        ])).toEqual([]);
    });

    it('drops peers whose device id or display name is not a string', () => {
        expect(normaliseSyncPeers([
            { deviceId: 42, displayName: 'Mac mini' },
            { deviceId: 'dev_a', displayName: { name: 'x' } },
            { deviceId: null, displayName: null },
            { deviceId: true, displayName: true },
            { deviceId: ['dev_a'], displayName: ['Mac mini'] },
        ])).toEqual([]);
    });

    // ポートは数値のみ受け付ける。文字列で来た場合は未設定扱いにする
    it('ignores a port supplied as a string and leaves it undefined', () => {
        const peers = normaliseSyncPeers([
            { deviceId: 'dev_a', displayName: 'A', port: '8765' },
        ]);
        expect(peers).toHaveLength(1);
        expect(peers[0].port).toBeUndefined();
    });

    it('ignores NaN, Infinity, and non-numeric ports', () => {
        const peers = normaliseSyncPeers([
            { deviceId: 'dev_a', displayName: 'A', port: Number.NaN },
            { deviceId: 'dev_b', displayName: 'B', port: Number.POSITIVE_INFINITY },
            { deviceId: 'dev_c', displayName: 'C', port: null },
            { deviceId: 'dev_d', displayName: 'D', port: { port: 8765 } },
        ]);
        expect(peers.map(peer => peer.port)).toEqual([undefined, undefined, undefined, undefined]);
    });

    it('coerces non-array hosts and roles to empty arrays', () => {
        expect(normaliseSyncPeers([
            { deviceId: 'dev_a', displayName: 'A', hosts: '192.168.0.1', roles: 'LibraryHost' },
            { deviceId: 'dev_b', displayName: 'B', hosts: { 0: '192.168.0.1' }, roles: 42 },
            { deviceId: 'dev_c', displayName: 'C', hosts: null, roles: undefined },
        ]).map(peer => [peer.hosts, peer.roles])).toEqual([
            [[], []],
            [[], []],
            [[], []],
        ]);
    });

    it('filters non-string and empty entries out of hosts and roles', () => {
        const peers = normaliseSyncPeers([
            {
                deviceId: 'dev_a',
                displayName: 'A',
                hosts: ['192.168.0.1', '', '   ', 42, null, undefined, { host: 'x' }, ' 192.168.0.2 '],
                roles: ['LibraryHost', '', 7, false, '   ', '  PlaybackTarget  '],
            },
        ]);
        expect(peers[0].hosts).toEqual(['192.168.0.1', '192.168.0.2']);
        expect(peers[0].roles).toEqual(['LibraryHost', 'PlaybackTarget']);
    });

    // トリム後に一致する host は hosts に重複追加しない
    it('does not duplicate a host that already appears in the padded host list', () => {
        const peers = normaliseSyncPeers([
            { deviceId: 'dev_a', displayName: 'A', host: '10.0.0.2', hosts: ['  10.0.0.2  '] },
        ]);
        expect(peers[0].hosts).toEqual(['10.0.0.2']);
    });

    it('prepends a trimmed host that is missing from the host list', () => {
        const peers = normaliseSyncPeers([
            { deviceId: 'dev_a', displayName: 'A', host: '  10.0.0.1  ', hosts: ['10.0.0.2'] },
        ]);
        expect(peers[0].host).toBe('10.0.0.1');
        expect(peers[0].hosts).toEqual(['10.0.0.1', '10.0.0.2']);
    });

    it('coerces a non-string host and reachable URL to empty strings', () => {
        const peers = normaliseSyncPeers([
            { deviceId: 'dev_a', displayName: 'A', host: 42, reachableBaseUrl: { url: 'x' } },
        ]);
        expect(peers[0].host).toBe('');
        expect(peers[0].reachableBaseUrl).toBe('');
        expect(peers[0].hosts).toEqual([]);
    });

    it('coerces null and undefined host and reachable URL to empty strings', () => {
        const peers = normaliseSyncPeers([
            { deviceId: 'dev_a', displayName: 'A', host: null, reachableBaseUrl: undefined },
            { deviceId: 'dev_b', displayName: 'B' },
        ]);
        expect(peers.map(peer => peer.host)).toEqual(['', '']);
        expect(peers.map(peer => peer.reachableBaseUrl)).toEqual(['', '']);
    });

    it('treats a blank host as absent instead of adding it to the host list', () => {
        const peers = normaliseSyncPeers([
            { deviceId: 'dev_a', displayName: 'A', host: '   ', hosts: ['10.0.0.5'] },
        ]);
        expect(peers[0].host).toBe('');
        expect(peers[0].hosts).toEqual(['10.0.0.5']);
    });

    it('returns an empty list for non-array peer payloads', () => {
        expect(normaliseSyncPeers('dev_a')).toEqual([]);
        expect(normaliseSyncPeers({ deviceId: 'dev_a' })).toEqual([]);
        expect(normaliseSyncPeers(42)).toEqual([]);
        expect(normaliseSyncPeers(null)).toEqual([]);
        expect(normaliseSyncPeers(undefined)).toEqual([]);
    });

    it('skips primitive entries inside the peer array', () => {
        expect(normaliseSyncPeers(['dev_a', 42, null, undefined, true])).toEqual([]);
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

    // 異常系: 保存済み端末レコードの前後空白は落としてから使う
    it('trims whitespace from device identity and base URL', () => {
        expect(normaliseSyncDevices([
            {
                deviceId: '  dev_mac_mini  ',
                displayName: '  YukinoMac-mini  ',
                baseUrl: '  http://192.168.0.226:8765  ',
                paired: true,
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

    it('falls back to the device id when the display name is blank or not a string', () => {
        expect(normaliseSyncDevices([
            { deviceId: 'dev_a', displayName: '   ', paired: false },
            { deviceId: 'dev_b', displayName: 42, paired: false },
            { deviceId: 'dev_c', displayName: null, paired: false },
            { deviceId: 'dev_d', paired: false },
        ]).map(device => device.displayName)).toEqual(['dev_a', 'dev_b', 'dev_c', 'dev_d']);
    });

    it('drops devices whose device id is blank or not a string', () => {
        expect(normaliseSyncDevices([
            { deviceId: '   ', displayName: 'A' },
            { deviceId: 42, displayName: 'A' },
            { deviceId: null, displayName: 'A' },
            { deviceId: {}, displayName: 'A' },
            { deviceId: true, displayName: 'A' },
        ])).toEqual([]);
    });

    it('coerces a non-string base URL to an empty string', () => {
        expect(normaliseSyncDevices([
            { deviceId: 'dev_a', displayName: 'A', baseUrl: 8765 },
            { deviceId: 'dev_b', displayName: 'B', baseUrl: null },
            { deviceId: 'dev_c', displayName: 'C', baseUrl: { url: 'x' } },
            { deviceId: 'dev_d', displayName: 'D', baseUrl: undefined },
        ]).map(device => device.baseUrl)).toEqual(['', '', '', '']);
    });

    it('omits roles when the payload is not an array', () => {
        expect(normaliseSyncDevices([
            { deviceId: 'dev_a', displayName: 'A', roles: 'LibraryHost' },
            { deviceId: 'dev_b', displayName: 'B', roles: 42 },
            { deviceId: 'dev_c', displayName: 'C', roles: { 0: 'LibraryHost' } },
        ]).map(device => device.roles)).toEqual([undefined, undefined, undefined]);
    });

    it('filters non-string and empty role entries', () => {
        expect(normaliseSyncDevices([
            { deviceId: 'dev_a', displayName: 'A', roles: ['  LibraryHost  ', '', 42, null, '   ', 'PlaybackTarget'] },
        ])[0].roles).toEqual(['LibraryHost', 'PlaybackTarget']);
    });

    it('omits roles when every entry is filtered out', () => {
        expect(normaliseSyncDevices([
            { deviceId: 'dev_a', displayName: 'A', roles: ['', '   ', 42, null, false] },
        ])[0].roles).toBeUndefined();
    });

    it('treats a non-boolean paired flag as not paired', () => {
        expect(normaliseSyncDevices([
            { deviceId: 'dev_a', displayName: 'A', paired: 'true' },
            { deviceId: 'dev_b', displayName: 'B', paired: 1 },
            { deviceId: 'dev_c', displayName: 'C' },
        ]).map(device => device.paired)).toEqual([false, false, false]);
    });

    it('returns an empty list for non-array device payloads', () => {
        expect(normaliseSyncDevices('dev_a')).toEqual([]);
        expect(normaliseSyncDevices({ deviceId: 'dev_a' })).toEqual([]);
        expect(normaliseSyncDevices(42)).toEqual([]);
        expect(normaliseSyncDevices(null)).toEqual([]);
        expect(normaliseSyncDevices(undefined)).toEqual([]);
    });

    it('skips primitive entries inside the device array', () => {
        expect(normaliseSyncDevices(['dev_a', 42, null, undefined, true])).toEqual([]);
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

    // 異常系: 前後空白まみれのペイロードから作った peer/device でも正しく突き合わせできる
    it('merges peers and devices built from padded and dirty payloads', () => {
        const peers = mergeSyncPeersWithDevices(
            normaliseSyncPeers([
                {
                    deviceId: '  dev_mac_mini  ',
                    displayName: '  peer name  ',
                    hosts: ['  192.168.0.226  ', '', 42],
                    roles: ['', 42, '   '],
                    port: '8765',
                },
            ]),
            normaliseSyncDevices([
                {
                    deviceId: '  dev_mac_mini  ',
                    displayName: '  YukinoMac-mini  ',
                    baseUrl: '  http://192.168.0.226:8765  ',
                    paired: true,
                    roles: ['  LibraryHost  ', ''],
                },
            ])
        );

        expect(peers).toEqual([
            {
                deviceId: 'dev_mac_mini',
                displayName: 'YukinoMac-mini',
                host: '192.168.0.226',
                hosts: ['192.168.0.226'],
                port: 8765,
                roles: ['LibraryHost'],
                reachableBaseUrl: 'http://192.168.0.226:8765',
                paired: true,
            },
        ]);
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

describe('manualSyncPeerBaseUrl', () => {
    it('uses the default UX Sync port for a bare IPv4 address', () => {
        expect(manualSyncPeerBaseUrl('192.168.0.143')).toBe('http://192.168.0.143:8765');
    });

    it('uses the supplied port for a bare host', () => {
        expect(manualSyncPeerBaseUrl('192.168.0.143', '9000')).toBe('http://192.168.0.143:9000');
    });

    it('preserves host:port input and ignores the separate port field', () => {
        expect(manualSyncPeerBaseUrl('192.168.0.143:8765', '9000')).toBe('http://192.168.0.143:8765');
    });

    it('preserves full URLs and removes trailing slashes', () => {
        expect(manualSyncPeerBaseUrl('http://host:8765/')).toBe('http://host:8765');
    });

    it('returns null for empty or unsafe input', () => {
        expect(manualSyncPeerBaseUrl('')).toBeNull();
        expect(manualSyncPeerBaseUrl('   ')).toBeNull();
        expect(manualSyncPeerBaseUrl('host\nname')).toBeNull();
    });

    // 異常系: 手入力の前後空白は URL 組み立て前に落とす
    it('trims whitespace around the manual host and port', () => {
        expect(manualSyncPeerBaseUrl('  192.168.0.143  ', '  9000  ')).toBe('http://192.168.0.143:9000');
        expect(manualSyncPeerBaseUrl('\t192.168.0.143 ')).toBe('http://192.168.0.143:8765');
        expect(manualSyncPeerBaseUrl('  http://host:8765/  ')).toBe('http://host:8765');
    });

    it('returns null when the host is not a string', () => {
        expect(manualSyncPeerBaseUrl(42 as unknown as string)).toBeNull();
        expect(manualSyncPeerBaseUrl({} as unknown as string)).toBeNull();
        expect(manualSyncPeerBaseUrl(null as unknown as string)).toBeNull();
        expect(manualSyncPeerBaseUrl(undefined as unknown as string)).toBeNull();
    });

    it('ignores a non-string port and falls back to the default port', () => {
        expect(manualSyncPeerBaseUrl('192.168.0.143', 9000 as unknown as string)).toBe('http://192.168.0.143:8765');
        expect(manualSyncPeerBaseUrl('192.168.0.143', null as unknown as string)).toBe('http://192.168.0.143:8765');
        expect(manualSyncPeerBaseUrl('192.168.0.143', {} as unknown as string)).toBe('http://192.168.0.143:8765');
    });

    it('returns null for a port that is not a plain positive integer within range', () => {
        expect(manualSyncPeerBaseUrl('192.168.0.143', '90a0')).toBeNull();
        expect(manualSyncPeerBaseUrl('192.168.0.143', '-1')).toBeNull();
        expect(manualSyncPeerBaseUrl('192.168.0.143', '65536')).toBeNull();
        expect(manualSyncPeerBaseUrl('192.168.0.143', '0')).toBeNull();
        expect(manualSyncPeerBaseUrl('192.168.0.143', '80.5')).toBeNull();
    });
});

describe('startManualSyncPairing', () => {
    it('starts pairing with the base URL built from manual input', async () => {
        const calls: string[] = [];
        const result = await startManualSyncPairing('192.168.0.143', '', async baseUrl => {
            calls.push(baseUrl);
            return {
                baseUrl,
                sessionId: 'sess_manual',
                localDeviceId: 'dev_local',
                remoteDeviceId: 'dev_remote',
                remoteDisplayName: 'Manual peer',
                code: '123456',
                expiresAt: '2026-06-10T00:00:00Z',
            };
        });

        expect(calls).toEqual(['http://192.168.0.143:8765']);
        expect(result?.peer.reachableBaseUrl).toBe('http://192.168.0.143:8765');
        expect(result?.started?.code).toBe('123456');
    });

    it('does not call pairing when manual input is empty', async () => {
        let called = false;
        const result = await startManualSyncPairing('', '', async () => {
            called = true;
            throw new Error('should not be called');
        });

        expect(result).toBeNull();
        expect(called).toBe(false);
    });

    // 異常系: 手入力とペアリング応答の両方に前後空白が混ざっていても正規化される
    it('builds the base URL and pairing session from padded manual input', async () => {
        const calls: string[] = [];
        const result = await startManualSyncPairing('  192.168.0.143  ', '  9000  ', async baseUrl => {
            calls.push(baseUrl);
            return {
                baseUrl,
                sessionId: '  sess_manual  ',
                localDeviceId: ' dev_local ',
                remoteDeviceId: ' dev_remote ',
                remoteDisplayName: ' Manual peer ',
                code: ' 123456 ',
                expiresAt: 42,
            };
        });

        expect(calls).toEqual(['http://192.168.0.143:9000']);
        expect(result?.started.sessionId).toBe('sess_manual');
        expect(result?.started.code).toBe('123456');
        expect(result?.started.remoteDisplayName).toBe('Manual peer');
        expect(result?.started.expiresAt).toBe('');
        expect(result?.peer.displayName).toBe('192.168.0.143');
        expect(result?.peer.host).toBe('192.168.0.143');
        expect(result?.peer.hosts).toEqual(['192.168.0.143']);
        expect(result?.peer.port).toBe(9000);
    });

    it('rejects a pairing response whose required fields are only whitespace', async () => {
        await expect(startManualSyncPairing('192.168.0.143', '', async () => ({
            baseUrl: '   ',
            sessionId: '   ',
            localDeviceId: '   ',
            remoteDeviceId: '   ',
            code: '   ',
        }))).rejects.toThrow('ペアリング開始応答が不正です。');
    });

    it('rejects a pairing response whose required fields are not strings', async () => {
        await expect(startManualSyncPairing('192.168.0.143', '', async () => ({
            baseUrl: 1,
            sessionId: 2,
            localDeviceId: 3,
            remoteDeviceId: 4,
            code: 123456,
        }))).rejects.toThrow('ペアリング開始応答が不正です。');
    });

    it('does not call pairing when the manual host is only whitespace or not a string', async () => {
        let called = false;
        const failIfCalled = async () => {
            called = true;
            throw new Error('should not be called');
        };

        expect(await startManualSyncPairing('   ', '', failIfCalled)).toBeNull();
        expect(await startManualSyncPairing(42 as unknown as string, '', failIfCalled)).toBeNull();
        expect(called).toBe(false);
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

    // 異常系: HTTP 応答に混ざった前後空白は落としてから保持する
    it('trims whitespace from every pairing start field', () => {
        expect(normaliseSyncPairingStart({
            baseUrl: '  http://mainPC.local:8765  ',
            sessionId: '\tsess_remote_1\n',
            localDeviceId: ' dev_local ',
            remoteDeviceId: ' dev_remote ',
            remoteDisplayName: '  mainPC  ',
            code: ' 123456 ',
            expiresAt: ' 2026-06-08T12:02:00Z ',
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

    it('rejects a payload whose required fields are only whitespace', () => {
        expect(normaliseSyncPairingStart({
            baseUrl: '   ',
            sessionId: 'sess_remote_1',
            localDeviceId: 'dev_local',
            remoteDeviceId: 'dev_remote',
            code: '123456',
        })).toBeNull();
        expect(normaliseSyncPairingStart({
            baseUrl: 'http://mainPC.local:8765',
            sessionId: 'sess_remote_1',
            localDeviceId: 'dev_local',
            remoteDeviceId: 'dev_remote',
            code: '\t\n ',
        })).toBeNull();
        expect(normaliseSyncPairingStart({
            baseUrl: 'http://mainPC.local:8765',
            sessionId: '  ',
            localDeviceId: 'dev_local',
            remoteDeviceId: 'dev_remote',
            code: '123456',
        })).toBeNull();
    });

    it('rejects a payload whose required fields are not strings', () => {
        expect(normaliseSyncPairingStart({
            baseUrl: 8765,
            sessionId: 1,
            localDeviceId: 2,
            remoteDeviceId: 3,
            code: 123456,
        })).toBeNull();
        expect(normaliseSyncPairingStart({
            baseUrl: { url: 'http://mainPC.local:8765' },
            sessionId: ['sess_remote_1'],
            localDeviceId: true,
            remoteDeviceId: {},
            code: 123456,
        })).toBeNull();
    });

    it('coerces non-string optional fields to empty strings', () => {
        expect(normaliseSyncPairingStart({
            baseUrl: 'http://mainPC.local:8765',
            sessionId: 'sess_remote_1',
            localDeviceId: 'dev_local',
            remoteDeviceId: 'dev_remote',
            remoteDisplayName: 42,
            code: '123456',
            expiresAt: { at: 'soon' },
        })).toEqual({
            baseUrl: 'http://mainPC.local:8765',
            sessionId: 'sess_remote_1',
            localDeviceId: 'dev_local',
            remoteDeviceId: 'dev_remote',
            remoteDisplayName: '',
            code: '123456',
            expiresAt: '',
        });
    });

    it('coerces null, undefined, and missing optional fields to empty strings', () => {
        expect(normaliseSyncPairingStart({
            baseUrl: 'http://mainPC.local:8765',
            sessionId: 'sess_remote_1',
            localDeviceId: 'dev_local',
            remoteDeviceId: 'dev_remote',
            remoteDisplayName: null,
            code: '123456',
            expiresAt: undefined,
        })).toEqual({
            baseUrl: 'http://mainPC.local:8765',
            sessionId: 'sess_remote_1',
            localDeviceId: 'dev_local',
            remoteDeviceId: 'dev_remote',
            remoteDisplayName: '',
            code: '123456',
            expiresAt: '',
        });
    });

    it('rejects non-object pairing start payloads', () => {
        expect(normaliseSyncPairingStart(null)).toBeNull();
        expect(normaliseSyncPairingStart(undefined)).toBeNull();
        expect(normaliseSyncPairingStart('sess_remote_1')).toBeNull();
        expect(normaliseSyncPairingStart(42)).toBeNull();
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

    // 異常系: 確認応答の前後空白は落としてから保持する
    it('trims whitespace from the confirmed device identity', () => {
        expect(normaliseSyncPairingConfirm({
            remoteDeviceId: '  dev_remote  ',
            remoteDisplayName: '\tmainPC ',
            tokenSaved: true,
        })).toEqual({
            remoteDeviceId: 'dev_remote',
            remoteDisplayName: 'mainPC',
            tokenSaved: true,
        });
    });

    it('rejects a confirm payload whose remote device id is blank or not a string', () => {
        expect(normaliseSyncPairingConfirm({ remoteDeviceId: '   ', remoteDisplayName: 'mainPC' })).toBeNull();
        expect(normaliseSyncPairingConfirm({ remoteDeviceId: 42, remoteDisplayName: 'mainPC' })).toBeNull();
        expect(normaliseSyncPairingConfirm({ remoteDeviceId: null })).toBeNull();
        expect(normaliseSyncPairingConfirm({ remoteDeviceId: {} })).toBeNull();
        expect(normaliseSyncPairingConfirm({ remoteDisplayName: 'mainPC' })).toBeNull();
    });

    it('coerces a non-string display name to an empty string', () => {
        expect(normaliseSyncPairingConfirm({
            remoteDeviceId: 'dev_remote',
            remoteDisplayName: 42,
            tokenSaved: true,
        })).toEqual({
            remoteDeviceId: 'dev_remote',
            remoteDisplayName: '',
            tokenSaved: true,
        });
        expect(normaliseSyncPairingConfirm({
            remoteDeviceId: 'dev_remote',
            remoteDisplayName: null,
        })).toEqual({
            remoteDeviceId: 'dev_remote',
            remoteDisplayName: '',
            tokenSaved: false,
        });
    });

    it('treats a non-boolean tokenSaved flag as false', () => {
        expect(normaliseSyncPairingConfirm({ remoteDeviceId: 'dev_remote', tokenSaved: 'true' })?.tokenSaved).toBe(false);
        expect(normaliseSyncPairingConfirm({ remoteDeviceId: 'dev_remote', tokenSaved: 1 })?.tokenSaved).toBe(false);
    });

    it('rejects non-object confirm payloads', () => {
        expect(normaliseSyncPairingConfirm(null)).toBeNull();
        expect(normaliseSyncPairingConfirm(undefined)).toBeNull();
        expect(normaliseSyncPairingConfirm('dev_remote')).toBeNull();
        expect(normaliseSyncPairingConfirm(42)).toBeNull();
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

    // 異常系: 曲数カウンタは 0 以上の整数に矯正される
    it('coerces negative pull counters to zero', () => {
        expect(normaliseSyncPullResult({
            remoteDeviceId: 'dev_mac_mini',
            remoteDisplayName: 'YukinoMac-mini',
            downloaded: -2,
            skipped: -1,
            failed: -0.5,
        })).toEqual({
            remoteDeviceId: 'dev_mac_mini',
            remoteDisplayName: 'YukinoMac-mini',
            downloaded: 0,
            skipped: 0,
            failed: 0,
            importedPaths: [],
            errors: [],
        });
    });

    it('coerces NaN and Infinity pull counters to zero', () => {
        expect(normaliseSyncPullResult({
            remoteDeviceId: 'dev_mac_mini',
            remoteDisplayName: 'YukinoMac-mini',
            downloaded: Number.NaN,
            skipped: Number.POSITIVE_INFINITY,
            failed: Number.NEGATIVE_INFINITY,
        })).toEqual({
            remoteDeviceId: 'dev_mac_mini',
            remoteDisplayName: 'YukinoMac-mini',
            downloaded: 0,
            skipped: 0,
            failed: 0,
            importedPaths: [],
            errors: [],
        });
    });

    it('floors fractional pull counters', () => {
        expect(normaliseSyncPullResult({
            remoteDeviceId: 'dev_mac_mini',
            remoteDisplayName: 'YukinoMac-mini',
            downloaded: 2.9,
            skipped: 1.5,
            failed: 0.9,
        })).toEqual({
            remoteDeviceId: 'dev_mac_mini',
            remoteDisplayName: 'YukinoMac-mini',
            downloaded: 2,
            skipped: 1,
            failed: 0,
            importedPaths: [],
            errors: [],
        });
    });

    it('coerces string, boolean, and nullish pull counters to zero', () => {
        expect(normaliseSyncPullResult({
            remoteDeviceId: 'dev_mac_mini',
            remoteDisplayName: 'YukinoMac-mini',
            downloaded: '2',
            skipped: true,
            failed: null,
        })).toEqual({
            remoteDeviceId: 'dev_mac_mini',
            remoteDisplayName: 'YukinoMac-mini',
            downloaded: 0,
            skipped: 0,
            failed: 0,
            importedPaths: [],
            errors: [],
        });
    });

    it('coerces non-array importedPaths and errors to empty arrays', () => {
        expect(normaliseSyncPullResult({
            remoteDeviceId: 'dev_mac_mini',
            importedPaths: 'C:\\song.flac',
            errors: 'network error',
        })).toEqual({
            remoteDeviceId: 'dev_mac_mini',
            remoteDisplayName: '',
            downloaded: 0,
            skipped: 0,
            failed: 0,
            importedPaths: [],
            errors: [],
        });
        expect(normaliseSyncPullResult({
            remoteDeviceId: 'dev_mac_mini',
            importedPaths: { 0: 'C:\\song.flac' },
            errors: 42,
        })?.importedPaths).toEqual([]);
        expect(normaliseSyncPullResult({ remoteDeviceId: 'dev_mac_mini', errors: 42 })?.errors).toEqual([]);
        expect(normaliseSyncPullResult({ remoteDeviceId: 'dev_mac_mini', errors: null })?.errors).toEqual([]);
    });

    it('filters non-string and empty entries from importedPaths and errors', () => {
        const result = normaliseSyncPullResult({
            remoteDeviceId: 'dev_mac_mini',
            importedPaths: ['  C:\\song.flac  ', '', '   ', 42, null, undefined, { path: 'x' }],
            errors: ['  network error  ', '', 7, false, '   ', 'timeout'],
        });
        expect(result?.importedPaths).toEqual(['C:\\song.flac']);
        expect(result?.errors).toEqual(['network error', 'timeout']);
    });

    it('trims whitespace from the remote device identity', () => {
        expect(normaliseSyncPullResult({
            remoteDeviceId: '  dev_mac_mini  ',
            remoteDisplayName: '\tYukinoMac-mini\n',
            downloaded: 2,
        })).toEqual({
            remoteDeviceId: 'dev_mac_mini',
            remoteDisplayName: 'YukinoMac-mini',
            downloaded: 2,
            skipped: 0,
            failed: 0,
            importedPaths: [],
            errors: [],
        });
    });

    it('coerces a non-string remote display name to an empty string', () => {
        expect(normaliseSyncPullResult({ remoteDeviceId: 'dev_mac_mini', remoteDisplayName: 42 })?.remoteDisplayName).toBe('');
        expect(normaliseSyncPullResult({ remoteDeviceId: 'dev_mac_mini', remoteDisplayName: null })?.remoteDisplayName).toBe('');
        expect(normaliseSyncPullResult({ remoteDeviceId: 'dev_mac_mini', remoteDisplayName: { name: 'x' } })?.remoteDisplayName).toBe('');
        expect(normaliseSyncPullResult({ remoteDeviceId: 'dev_mac_mini' })?.remoteDisplayName).toBe('');
    });

    it('rejects a pull result whose remote device id is blank or not a string', () => {
        expect(normaliseSyncPullResult({ remoteDeviceId: '   ', downloaded: 1 })).toBeNull();
        expect(normaliseSyncPullResult({ remoteDeviceId: 42, downloaded: 1 })).toBeNull();
        expect(normaliseSyncPullResult({ remoteDeviceId: null, downloaded: 1 })).toBeNull();
        expect(normaliseSyncPullResult({ remoteDeviceId: {}, downloaded: 1 })).toBeNull();
    });

    it('rejects non-object pull payloads', () => {
        expect(normaliseSyncPullResult(null)).toBeNull();
        expect(normaliseSyncPullResult(undefined)).toBeNull();
        expect(normaliseSyncPullResult('dev_mac_mini')).toBeNull();
        expect(normaliseSyncPullResult(42)).toBeNull();
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

    // 異常系: 曲数カウンタは 0 以上の整数に矯正される
    it('coerces negative push counters to zero', () => {
        expect(normaliseSyncPushResult({
            remoteDeviceId: 'dev_mainpc',
            remoteDisplayName: 'mainPC',
            transferred: -2,
            skipped: -1,
            failed: -0.5,
        })).toEqual({
            remoteDeviceId: 'dev_mainpc',
            remoteDisplayName: 'mainPC',
            transferred: 0,
            skipped: 0,
            failed: 0,
            encodingMode: 'original',
            importedPaths: [],
            errors: [],
        });
    });

    it('coerces NaN and Infinity push counters to zero', () => {
        expect(normaliseSyncPushResult({
            remoteDeviceId: 'dev_mainpc',
            remoteDisplayName: 'mainPC',
            transferred: Number.NaN,
            skipped: Number.POSITIVE_INFINITY,
            failed: Number.NEGATIVE_INFINITY,
        })).toEqual({
            remoteDeviceId: 'dev_mainpc',
            remoteDisplayName: 'mainPC',
            transferred: 0,
            skipped: 0,
            failed: 0,
            encodingMode: 'original',
            importedPaths: [],
            errors: [],
        });
    });

    it('floors fractional push counters', () => {
        expect(normaliseSyncPushResult({
            remoteDeviceId: 'dev_mainpc',
            remoteDisplayName: 'mainPC',
            transferred: 2.9,
            skipped: 1.5,
            failed: 0.9,
        })).toEqual({
            remoteDeviceId: 'dev_mainpc',
            remoteDisplayName: 'mainPC',
            transferred: 2,
            skipped: 1,
            failed: 0,
            encodingMode: 'original',
            importedPaths: [],
            errors: [],
        });
    });

    it('coerces string, boolean, and nullish push counters to zero', () => {
        expect(normaliseSyncPushResult({
            remoteDeviceId: 'dev_mainpc',
            transferred: '2',
            skipped: true,
            failed: null,
        })).toEqual({
            remoteDeviceId: 'dev_mainpc',
            remoteDisplayName: '',
            transferred: 0,
            skipped: 0,
            failed: 0,
            encodingMode: 'original',
            importedPaths: [],
            errors: [],
        });
    });

    it('coerces non-array importedPaths and errors to empty arrays', () => {
        expect(normaliseSyncPushResult({
            remoteDeviceId: 'dev_mainpc',
            importedPaths: 'C:\\song.flac',
            errors: 'network error',
        })?.importedPaths).toEqual([]);
        expect(normaliseSyncPushResult({
            remoteDeviceId: 'dev_mainpc',
            importedPaths: { 0: 'C:\\song.flac' },
            errors: 42,
        })?.errors).toEqual([]);
        expect(normaliseSyncPushResult({ remoteDeviceId: 'dev_mainpc', errors: null })?.errors).toEqual([]);
    });

    it('filters non-string and empty entries from importedPaths and errors', () => {
        const result = normaliseSyncPushResult({
            remoteDeviceId: 'dev_mainpc',
            importedPaths: ['  C:\\song.flac  ', '', '   ', 42, null, undefined, { path: 'x' }],
            errors: ['  upload failed  ', '', 7, false, '   ', 'timeout'],
        });
        expect(result?.importedPaths).toEqual(['C:\\song.flac']);
        expect(result?.errors).toEqual(['upload failed', 'timeout']);
    });

    // encodingMode は空文字なら original にフォールバックする
    it('falls back to the original encoding mode for blank or non-string values', () => {
        expect(normaliseSyncPushResult({ remoteDeviceId: 'dev_mainpc', encodingMode: '   ' })?.encodingMode).toBe('original');
        expect(normaliseSyncPushResult({ remoteDeviceId: 'dev_mainpc', encodingMode: 42 })?.encodingMode).toBe('original');
        expect(normaliseSyncPushResult({ remoteDeviceId: 'dev_mainpc', encodingMode: null })?.encodingMode).toBe('original');
        expect(normaliseSyncPushResult({ remoteDeviceId: 'dev_mainpc', encodingMode: { mode: 'mp3_320' } })?.encodingMode).toBe('original');
        expect(normaliseSyncPushResult({ remoteDeviceId: 'dev_mainpc', encodingMode: true })?.encodingMode).toBe('original');
    });

    it('trims a padded encoding mode', () => {
        expect(normaliseSyncPushResult({ remoteDeviceId: 'dev_mainpc', encodingMode: '  mp3_320  ' })?.encodingMode).toBe('mp3_320');
    });

    it('trims whitespace from the remote device identity', () => {
        expect(normaliseSyncPushResult({
            remoteDeviceId: '  dev_mainpc  ',
            remoteDisplayName: '\tmainPC\n',
            transferred: 2,
        })).toEqual({
            remoteDeviceId: 'dev_mainpc',
            remoteDisplayName: 'mainPC',
            transferred: 2,
            skipped: 0,
            failed: 0,
            encodingMode: 'original',
            importedPaths: [],
            errors: [],
        });
    });

    it('coerces a non-string remote display name to an empty string', () => {
        expect(normaliseSyncPushResult({ remoteDeviceId: 'dev_mainpc', remoteDisplayName: 42 })?.remoteDisplayName).toBe('');
        expect(normaliseSyncPushResult({ remoteDeviceId: 'dev_mainpc', remoteDisplayName: null })?.remoteDisplayName).toBe('');
        expect(normaliseSyncPushResult({ remoteDeviceId: 'dev_mainpc' })?.remoteDisplayName).toBe('');
    });

    it('rejects a push result whose remote device id is blank or not a string', () => {
        expect(normaliseSyncPushResult({ remoteDeviceId: '   ', transferred: 1 })).toBeNull();
        expect(normaliseSyncPushResult({ remoteDeviceId: 42, transferred: 1 })).toBeNull();
        expect(normaliseSyncPushResult({ remoteDeviceId: null, transferred: 1 })).toBeNull();
        expect(normaliseSyncPushResult({ remoteDeviceId: {}, transferred: 1 })).toBeNull();
    });

    it('rejects non-object push payloads', () => {
        expect(normaliseSyncPushResult(null)).toBeNull();
        expect(normaliseSyncPushResult(undefined)).toBeNull();
        expect(normaliseSyncPushResult('dev_mainpc')).toBeNull();
        expect(normaliseSyncPushResult(42)).toBeNull();
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

    // 異常系: 進捗イベントの前後空白は落としてから保持する
    it('trims whitespace from the direction, stage, and file labels', () => {
        expect(normaliseSyncTransferProgress({
            direction: '  push  ',
            stage: '\tuploading\n',
            trackId: '  local-track-1  ',
            title: '  Local Song  ',
            fileName: '  local.mp3  ',
            encodingMode: '  mp3_320  ',
        })).toEqual({
            direction: 'push',
            stage: 'uploading',
            trackId: 'local-track-1',
            title: 'Local Song',
            fileName: 'local.mp3',
            current: 0,
            total: 0,
            bytesDone: 0,
            bytesTotal: 0,
            bytesPerSecond: 0,
            encodingMode: 'mp3_320',
        });
    });

    it('coerces negative counters and transfer speed to zero', () => {
        expect(normaliseSyncTransferProgress({
            direction: 'pull',
            stage: 'downloading',
            current: -1,
            total: -3,
            bytesDone: -1024,
            bytesTotal: -2048,
            bytesPerSecond: -512,
        })).toEqual({
            direction: 'pull',
            stage: 'downloading',
            trackId: '',
            title: '',
            fileName: '',
            current: 0,
            total: 0,
            bytesDone: 0,
            bytesTotal: 0,
            bytesPerSecond: 0,
            encodingMode: 'original',
        });
    });

    it('coerces NaN and Infinity counters and transfer speed to zero', () => {
        expect(normaliseSyncTransferProgress({
            direction: 'pull',
            stage: 'downloading',
            current: Number.NaN,
            total: Number.POSITIVE_INFINITY,
            bytesDone: Number.NEGATIVE_INFINITY,
            bytesTotal: Number.NaN,
            bytesPerSecond: Number.POSITIVE_INFINITY,
        })).toEqual({
            direction: 'pull',
            stage: 'downloading',
            trackId: '',
            title: '',
            fileName: '',
            current: 0,
            total: 0,
            bytesDone: 0,
            bytesTotal: 0,
            bytesPerSecond: 0,
            encodingMode: 'original',
        });
    });

    // カウンタは切り捨てるが、転送速度は小数のまま保持する
    it('floors fractional counters while keeping the fractional transfer speed', () => {
        expect(normaliseSyncTransferProgress({
            direction: 'push',
            stage: 'uploading',
            current: 1.9,
            total: 3.7,
            bytesDone: 1024.9,
            bytesTotal: 2048.4,
            bytesPerSecond: 1536.5,
        })).toEqual({
            direction: 'push',
            stage: 'uploading',
            trackId: '',
            title: '',
            fileName: '',
            current: 1,
            total: 3,
            bytesDone: 1024,
            bytesTotal: 2048,
            bytesPerSecond: 1536.5,
            encodingMode: 'original',
        });
    });

    it('coerces string, boolean, and nullish counters and speed to zero', () => {
        expect(normaliseSyncTransferProgress({
            direction: 'push',
            stage: 'uploading',
            current: '1',
            total: '3',
            bytesDone: true,
            bytesTotal: null,
            bytesPerSecond: '1572864',
        })).toEqual({
            direction: 'push',
            stage: 'uploading',
            trackId: '',
            title: '',
            fileName: '',
            current: 0,
            total: 0,
            bytesDone: 0,
            bytesTotal: 0,
            bytesPerSecond: 0,
            encodingMode: 'original',
        });
    });

    it('coerces non-string labels to empty strings', () => {
        const progress = normaliseSyncTransferProgress({
            direction: 'push',
            stage: 'uploading',
            trackId: 42,
            title: { title: 'Local Song' },
            fileName: null,
        });
        expect(progress?.trackId).toBe('');
        expect(progress?.title).toBe('');
        expect(progress?.fileName).toBe('');
    });

    it('rejects progress whose direction or stage is blank', () => {
        expect(normaliseSyncTransferProgress({ direction: '   ', stage: 'uploading' })).toBeNull();
        expect(normaliseSyncTransferProgress({ direction: 'push', stage: '\t\n ' })).toBeNull();
    });

    it('rejects progress whose direction or stage is not a string', () => {
        expect(normaliseSyncTransferProgress({ direction: 42, stage: 'uploading' })).toBeNull();
        expect(normaliseSyncTransferProgress({ direction: 'push', stage: 7 })).toBeNull();
        expect(normaliseSyncTransferProgress({ direction: null, stage: null })).toBeNull();
        expect(normaliseSyncTransferProgress({ direction: true, stage: true })).toBeNull();
    });

    it('falls back to the original encoding mode for blank or non-string values', () => {
        expect(normaliseSyncTransferProgress({ direction: 'push', stage: 'uploading', encodingMode: '   ' })?.encodingMode).toBe('original');
        expect(normaliseSyncTransferProgress({ direction: 'push', stage: 'uploading', encodingMode: 42 })?.encodingMode).toBe('original');
        expect(normaliseSyncTransferProgress({ direction: 'push', stage: 'uploading', encodingMode: null })?.encodingMode).toBe('original');
    });

    it('rejects non-object progress payloads', () => {
        expect(normaliseSyncTransferProgress(null)).toBeNull();
        expect(normaliseSyncTransferProgress(undefined)).toBeNull();
        expect(normaliseSyncTransferProgress('uploading')).toBeNull();
        expect(normaliseSyncTransferProgress(42)).toBeNull();
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

    // 異常系: 壊れた進捗値は表示から落とすか整数に丸める
    it('shows floored counters and hides an unusable transfer speed', () => {
        const progress = normaliseSyncTransferProgress({
            direction: 'push',
            stage: 'uploading',
            fileName: '  local.mp3  ',
            current: 1.9,
            total: 3.7,
            bytesPerSecond: '5000',
            encodingMode: '  mp3_320  ',
        });

        expect(progress && formatSyncTransferProgressSummary(progress)).toBe('転送中: local.mp3 (1 / 3) - MP3 320kbps');
    });

    it('hides the counters and speed when the backend sends negative values', () => {
        const progress = normaliseSyncTransferProgress({
            direction: 'pull',
            stage: 'downloading',
            fileName: 'remote.flac',
            current: -1,
            total: -3,
            bytesPerSecond: -1024,
        });

        expect(progress && formatSyncTransferProgressSummary(progress)).toBe('取得中: remote.flac');
    });

    it('falls back to the track id and the generic label for an unknown stage', () => {
        const progress = normaliseSyncTransferProgress({
            direction: '  pull  ',
            stage: '  waiting  ',
            trackId: '  local-track-1  ',
            fileName: 42,
            title: null,
        });

        expect(progress && formatSyncTransferProgressSummary(progress)).toBe('取得準備中: local-track-1');
    });

    it('falls back to the placeholder file label when every name is unusable', () => {
        const progress = normaliseSyncTransferProgress({
            direction: 'push',
            stage: 'done',
            trackId: '   ',
            title: 42,
            fileName: null,
        });

        expect(progress && formatSyncTransferProgressSummary(progress)).toBe('完了: 音源');
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
