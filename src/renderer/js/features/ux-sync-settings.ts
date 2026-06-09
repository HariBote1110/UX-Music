export interface SyncPeer {
    deviceId: string;
    displayName: string;
    host?: string;
    hosts: string[];
    port?: number;
    roles: string[];
    reachableBaseUrl?: string;
    paired?: boolean;
}

export interface SyncDevice {
    deviceId: string;
    displayName: string;
    baseUrl?: string;
    roles?: string[];
    paired: boolean;
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

export interface SyncPushResult {
    remoteDeviceId: string;
    remoteDisplayName: string;
    transferred: number;
    skipped: number;
    failed: number;
    encodingMode: string;
    importedPaths: string[];
    errors: string[];
}

export interface SyncTransferProgress {
    direction: string;
    stage: string;
    trackId: string;
    title: string;
    fileName: string;
    current: number;
    total: number;
    bytesDone: number;
    bytesTotal: number;
    bytesPerSecond: number;
    encodingMode: string;
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

export interface SyncPushActionState {
    canPush: boolean;
    status: string;
}

export interface SyncAutoResult {
    checkedDevices: number;
    syncedDevices: number;
    failedDevices: number;
    pushedPlayEvents: number;
    syncedArtwork: number;
    pulledTracks: number;
    skippedTracks: number;
    paused: boolean;
    pauseReason: string;
}

export function normaliseSyncMinFreeSpaceGB(raw: unknown): number {
    const value = typeof raw === 'number' ? raw : Number(raw);
    if (!Number.isFinite(value) || value <= 0) {
        return 0;
    }
    return Math.min(1024, Math.round(value * 10) / 10);
}

export function formatSyncFreeSpaceSafetyStatus(minFreeSpaceGB: number): string {
    const value = normaliseSyncMinFreeSpaceGB(minFreeSpaceGB);
    return value > 0
        ? `空き容量が ${value} GB 未満の場合は同期を停止します。`
        : '空き容量による同期停止は無効です。';
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

export function normaliseSyncDevices(rawDevices: unknown): SyncDevice[] {
    if (!Array.isArray(rawDevices)) {
        return [];
    }
    return rawDevices
        .map(normaliseSyncDevice)
        .filter((device): device is SyncDevice => device != null);
}

export function normaliseSyncAutoResult(raw: unknown): SyncAutoResult | null {
    if (!raw || typeof raw !== 'object') {
        return null;
    }
    const record = raw as Record<string, unknown>;
    return {
        checkedDevices: readCount(record.checkedDevices),
        syncedDevices: readCount(record.syncedDevices),
        failedDevices: readCount(record.failedDevices),
        pushedPlayEvents: readCount(record.pushedPlayEvents),
        syncedArtwork: readCount(record.syncedArtwork),
        pulledTracks: readCount(record.pulledTracks),
        skippedTracks: readCount(record.skippedTracks),
        paused: record.paused === true,
        pauseReason: readString(record.pauseReason),
    };
}

export function mergeSyncPeersWithDevices(peers: SyncPeer[], devices: SyncDevice[]): SyncPeer[] {
    const deviceById = new Map(devices.map(device => [device.deviceId, device]));
    const merged = peers.map(peer => {
        const device = deviceById.get(peer.deviceId);
        if (!device) {
            return peer;
        }
        const endpoint = parseSyncBaseUrl(device.baseUrl || '');
        return {
            ...peer,
            displayName: device.displayName || peer.displayName,
            roles: peer.roles.length > 0 ? peer.roles : device.roles ?? [],
            reachableBaseUrl: peer.reachableBaseUrl || device.baseUrl,
            host: peer.host || endpoint?.host,
            hosts: mergeHosts(peer.hosts, endpoint?.host),
            port: peer.port ?? endpoint?.port,
            paired: device.paired || peer.paired,
        };
    });
    const existingIds = new Set(merged.map(peer => peer.deviceId));
    for (const device of devices) {
        if (existingIds.has(device.deviceId)) {
            continue;
        }
        const endpoint = parseSyncBaseUrl(device.baseUrl || '');
        merged.push({
            deviceId: device.deviceId,
            displayName: device.displayName || device.deviceId,
            host: endpoint?.host,
            hosts: endpoint?.host ? [endpoint.host] : [],
            port: endpoint?.port,
            roles: device.roles ?? [],
            reachableBaseUrl: device.baseUrl,
            paired: device.paired,
        });
    }
    return merged;
}

export function syncPeerConnectionLabel(peer: SyncPeer): string {
    if (peer.paired) {
        return 'ペアリング済み';
    }
    return peer.reachableBaseUrl ? '接続候補' : '未確認';
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

export function normaliseSyncPushResult(raw: unknown): SyncPushResult | null {
    if (!raw || typeof raw !== 'object') {
        return null;
    }
    const record = raw as Record<string, unknown>;
    const result: SyncPushResult = {
        remoteDeviceId: readString(record.remoteDeviceId),
        remoteDisplayName: readString(record.remoteDisplayName),
        transferred: readCount(record.transferred),
        skipped: readCount(record.skipped),
        failed: readCount(record.failed),
        encodingMode: readString(record.encodingMode) || 'original',
        importedPaths: readStringArray(record.importedPaths),
        errors: readStringArray(record.errors),
    };
    if (!result.remoteDeviceId) {
        return null;
    }
    return result;
}

export function normaliseSyncTransferProgress(raw: unknown): SyncTransferProgress | null {
    if (!raw || typeof raw !== 'object') {
        return null;
    }
    const record = raw as Record<string, unknown>;
    const progress: SyncTransferProgress = {
        direction: readString(record.direction),
        stage: readString(record.stage),
        trackId: readString(record.trackId),
        title: readString(record.title),
        fileName: readString(record.fileName),
        current: readCount(record.current),
        total: readCount(record.total),
        bytesDone: readCount(record.bytesDone),
        bytesTotal: readCount(record.bytesTotal),
        bytesPerSecond: readFiniteNumber(record.bytesPerSecond),
        encodingMode: readString(record.encodingMode) || 'original',
    };
    if (!progress.direction || !progress.stage) {
        return null;
    }
    return progress;
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

export function syncPushActionState(hasPushBinding: boolean, selectedBaseUrl: string): SyncPushActionState {
    if (!hasPushBinding) {
        return { canPush: false, status: 'この環境では音源転送を利用できません' };
    }
    if (!selectedBaseUrl) {
        return { canPush: false, status: '転送先端末を選択してください' };
    }
    return { canPush: true, status: '待機中' };
}

export function formatSyncPullResultSummary(result: SyncPullResult): string {
    const name = result.remoteDisplayName || result.remoteDeviceId;
    return `${name}: 取得 ${result.downloaded}曲 / 既存 ${result.skipped}曲 / 失敗 ${result.failed}曲`;
}

export function formatSyncPushResultSummary(result: SyncPushResult): string {
    const name = result.remoteDisplayName || result.remoteDeviceId;
    return `${name}: 転送 ${result.transferred}曲 / 既存 ${result.skipped}曲 / 失敗 ${result.failed}曲`;
}

export function formatSyncAutoResultNotification(result: SyncAutoResult): string {
    if (result.paused) {
        return result.pauseReason === 'free-space-below-limit'
            ? 'UX Sync: 空き容量が少ないため同期を停止しました。'
            : 'UX Sync: 自動同期を停止しました。';
    }
    if (result.checkedDevices <= 0) {
        return '';
    }
    const parts = [
        result.pulledTracks > 0 ? `取得 ${result.pulledTracks}曲` : '',
        result.skippedTracks > 0 ? `既存 ${result.skippedTracks}曲` : '',
        result.pushedPlayEvents > 0 ? `再生回数 ${result.pushedPlayEvents}件` : '',
        result.syncedArtwork > 0 ? `ジャケット ${result.syncedArtwork}件` : '',
    ].filter(Boolean);
    if (parts.length === 0) {
        return result.syncedDevices > 0
            ? 'UX Sync: 接続できたため同期を確認しました。'
            : 'UX Sync: 接続を確認しましたが同期できませんでした。';
    }
    return `UX Sync: 接続できたため同期しました（${parts.join(' / ')}）`;
}

export function formatSyncTransferProgressSummary(progress: SyncTransferProgress): string {
    const label = syncTransferStageLabel(progress);
    const file = progress.fileName || progress.title || progress.trackId || '音源';
    const counters = progress.total > 0 ? ` (${progress.current} / ${progress.total})` : '';
    const speed = progress.bytesPerSecond > 0 ? ` - ${formatBytesPerSecond(progress.bytesPerSecond)}` : '';
    const encoding = progress.encodingMode === 'mp3_320' ? ' - MP3 320kbps' : '';
    return `${label}: ${file}${counters}${speed}${encoding}`;
}

export function syncTransferEncodingOptions(): Array<{ value: string; label: string }> {
    return [
        { value: 'original', label: '原本のまま' },
        { value: 'mp3_320', label: 'MP3 320kbps' },
    ];
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
        ...(record.paired === true ? { paired: true } : {}),
    };
}

function normaliseSyncDevice(raw: unknown): SyncDevice | null {
    if (!raw || typeof raw !== 'object') {
        return null;
    }
    const record = raw as Record<string, unknown>;
    const deviceId = readString(record.deviceId);
    const displayName = readString(record.displayName) || deviceId;
    if (!deviceId || !displayName) {
        return null;
    }
    const roles = readStringArray(record.roles);
    return {
        deviceId,
        displayName,
        baseUrl: readString(record.baseUrl),
        paired: record.paired === true,
        ...(roles.length > 0 ? { roles } : {}),
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

function readFiniteNumber(value: unknown): number {
    return typeof value === 'number' && Number.isFinite(value) && value > 0 ? value : 0;
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

function parseSyncBaseUrl(baseUrl: string): { host: string; port?: number } | null {
    if (!baseUrl) {
        return null;
    }
    try {
        const parsed = new URL(baseUrl);
        const port = parsed.port ? Number.parseInt(parsed.port, 10) : undefined;
        return {
            host: parsed.hostname,
            port: Number.isFinite(port) ? port : undefined,
        };
    } catch {
        return null;
    }
}

function mergeHosts(hosts: string[], extra?: string): string[] {
    const merged = [...hosts];
    if (extra && !merged.includes(extra)) {
        merged.push(extra);
    }
    return merged;
}

function syncTransferStageLabel(progress: SyncTransferProgress): string {
    switch (progress.stage) {
    case 'transcoding':
        return '変換中';
    case 'downloading':
        return '取得中';
    case 'uploading':
        return '転送中';
    case 'done':
        return '完了';
    case 'skipped':
        return '既存';
    case 'failed':
        return '失敗';
    default:
        return progress.direction === 'pull' ? '取得準備中' : '転送準備中';
    }
}

function formatBytesPerSecond(bytesPerSecond: number): string {
    const mib = bytesPerSecond / 1024 / 1024;
    if (mib >= 1) {
        return `${formatOneDecimal(mib)} MB/s`;
    }
    const kib = bytesPerSecond / 1024;
    return `${formatOneDecimal(kib)} KB/s`;
}

function formatOneDecimal(value: number): string {
    return (Math.round(value * 10) / 10).toFixed(1);
}
