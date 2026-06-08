export interface SyncPeer {
    deviceId: string;
    displayName: string;
    host?: string;
    hosts: string[];
    port?: number;
    roles: string[];
    reachableBaseUrl?: string;
}

export interface SyncPairingStart {
    baseUrl: string;
    sessionId: string;
    localDeviceId: string;
    remoteDeviceId: string;
    remoteDisplayName: string;
    code: string;
    expiresAt: string;
}

export interface SyncPairingConfirm {
    remoteDeviceId: string;
    remoteDisplayName: string;
    tokenSaved: boolean;
}

export interface SyncPullResult {
    remoteDeviceId: string;
    remoteDisplayName: string;
    downloaded: number;
    skipped: number;
    failed: number;
    importedPaths: string[];
    errors: string[];
}

export interface SyncSettingsEntryState {
    visible: boolean;
    canOpen: boolean;
    status: string;
}

export interface SyncPullActionState {
    canPull: boolean;
    status: string;
}

export function syncSettingsEntryState(hasSyncBindings: boolean): SyncSettingsEntryState {
    return hasSyncBindings
        ? { visible: true, canOpen: true, status: '利用可能' }
        : { visible: false, canOpen: false, status: 'この環境では利用できません' };
}

export function normaliseSyncPeers(rawPeers: unknown): SyncPeer[] {
    if (!Array.isArray(rawPeers)) {
        return [];
    }
    return rawPeers
        .map(normaliseSyncPeer)
        .filter((peer): peer is SyncPeer => peer != null);
}

export function formatSyncPeerEndpoint(peer: SyncPeer): string {
    if (peer.reachableBaseUrl) {
        return peer.reachableBaseUrl;
    }
    if (peer.host && peer.port) {
        return `http://${formatHost(peer.host)}:${peer.port}`;
    }
    const firstHost = peer.hosts[0];
    if (firstHost && peer.port) {
        return `http://${formatHost(firstHost)}:${peer.port}`;
    }
    return '未確認';
}

export function syncPeerPairingBaseUrl(peer: SyncPeer): string {
    const endpoint = formatSyncPeerEndpoint(peer);
    return endpoint === '未確認' ? '' : endpoint;
}

export function formatSyncPeerRoles(peer: SyncPeer): string {
    if (peer.roles.length === 0) {
        return '役割未取得';
    }
    return peer.roles.join(' / ');
}

export function normaliseSyncPairingStart(raw: unknown): SyncPairingStart | null {
    if (!raw || typeof raw !== 'object') {
        return null;
    }
    const record = raw as Record<string, unknown>;
    const start = {
        baseUrl: readString(record.baseUrl),
        sessionId: readString(record.sessionId),
        localDeviceId: readString(record.localDeviceId),
        remoteDeviceId: readString(record.remoteDeviceId),
        remoteDisplayName: readString(record.remoteDisplayName),
        code: readString(record.code),
        expiresAt: readString(record.expiresAt),
    };
    if (!start.baseUrl || !start.sessionId || !start.localDeviceId || !start.remoteDeviceId || !start.code) {
        return null;
    }
    return start;
}

export function normaliseSyncPairingConfirm(raw: unknown): SyncPairingConfirm | null {
    if (!raw || typeof raw !== 'object') {
        return null;
    }
    const record = raw as Record<string, unknown>;
    const confirm = {
        remoteDeviceId: readString(record.remoteDeviceId),
        remoteDisplayName: readString(record.remoteDisplayName),
        tokenSaved: record.tokenSaved === true,
    };
    if (!confirm.remoteDeviceId) {
        return null;
    }
    return confirm;
}

export function normaliseSyncPullResult(raw: unknown): SyncPullResult | null {
    if (!raw || typeof raw !== 'object') {
        return null;
    }
    const record = raw as Record<string, unknown>;
    const result: SyncPullResult = {
        remoteDeviceId: readString(record.remoteDeviceId),
        remoteDisplayName: readString(record.remoteDisplayName),
        downloaded: readCount(record.downloaded),
        skipped: readCount(record.skipped),
        failed: readCount(record.failed),
        importedPaths: readStringArray(record.importedPaths),
        errors: readStringArray(record.errors),
    };
    if (!result.remoteDeviceId) {
        return null;
    }
    return result;
}

export function syncPullActionState(hasPullBinding: boolean, selectedBaseUrl: string): SyncPullActionState {
    if (!hasPullBinding) {
        return { canPull: false, status: 'この環境では音源取得を利用できません' };
    }
    if (!selectedBaseUrl) {
        return { canPull: false, status: '同期元端末を選択してください' };
    }
    return { canPull: true, status: '待機中' };
}

export function formatSyncPullResultSummary(result: SyncPullResult): string {
    const name = result.remoteDisplayName || result.remoteDeviceId;
    return `${name}: 取得 ${result.downloaded}曲 / 既存 ${result.skipped}曲 / 失敗 ${result.failed}曲`;
}

function normaliseSyncPeer(raw: unknown): SyncPeer | null {
    if (!raw || typeof raw !== 'object') {
        return null;
    }
    const record = raw as Record<string, unknown>;
    const deviceId = readString(record.deviceId);
    const displayName = readString(record.displayName);
    if (!deviceId || !displayName) {
        return null;
    }
    const host = readString(record.host);
    const hosts = readStringArray(record.hosts);
    if (host && !hosts.includes(host)) {
        hosts.unshift(host);
    }
    return {
        deviceId,
        displayName,
        host,
        hosts,
        port: readNumber(record.port),
        roles: readStringArray(record.roles),
        reachableBaseUrl: readString(record.reachableBaseUrl),
    };
}

function readString(value: unknown): string {
    return typeof value === 'string' ? value.trim() : '';
}

function readNumber(value: unknown): number | undefined {
    return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}

function readCount(value: unknown): number {
    return typeof value === 'number' && Number.isFinite(value) && value > 0 ? Math.floor(value) : 0;
}

function readStringArray(value: unknown): string[] {
    if (!Array.isArray(value)) {
        return [];
    }
    return value
        .map(readString)
        .filter(Boolean);
}

function formatHost(host: string): string {
    return host.includes(':') && !host.startsWith('[') ? `[${host}]` : host;
}
