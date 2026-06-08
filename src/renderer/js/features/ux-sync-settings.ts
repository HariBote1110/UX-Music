export interface SyncPeer {
    deviceId: string;
    displayName: string;
    host?: string;
    hosts: string[];
    port?: number;
    roles: string[];
    reachableBaseUrl?: string;
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

export function formatSyncPeerRoles(peer: SyncPeer): string {
    if (peer.roles.length === 0) {
        return '役割未取得';
    }
    return peer.roles.join(' / ');
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
