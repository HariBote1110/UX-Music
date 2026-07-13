// ループバック embed ホストページ（http://127.0.0.1:<port>/embed）と
// 親ウィンドウの postMessage プロトコルの純粋ロジック。
// DOM や Wails には依存しない。

/** IFrame Player API の状態コード（公式定義と一致させる）。 */
export const EMBED_PLAYER_STATE = {
    ENDED: 0,
    PLAYING: 1,
    PAUSED: 2,
} as const;

export type EmbedHostMessage =
    | { type: 'ready' }
    | { type: 'state'; state: number }
    | { type: 'error'; code: number }
    | { type: 'time'; currentTime: number; duration: number; state: number };

export type EmbedCommand =
    | { source: 'ux-embed-cmd'; cmd: 'play' | 'pause' | 'unmute' }
    | { source: 'ux-embed-cmd'; cmd: 'seek'; seconds: number };

function finiteOrZero(value: unknown): number {
    return typeof value === 'number' && Number.isFinite(value) ? value : 0;
}

/**
 * ホストページからの message イベント data を検証して型付きメッセージへ
 * 変換する。プロトコル外のデータは null。
 */
export function parseEmbedHostMessage(data: unknown): EmbedHostMessage | null {
    if (typeof data !== 'object' || data === null) return null;
    const record = data as Record<string, unknown>;
    if (record.source !== 'ux-embed') return null;

    switch (record.type) {
        case 'ready':
            return { type: 'ready' };
        case 'state':
            if (typeof record.state !== 'number') return null;
            return { type: 'state', state: record.state };
        case 'error':
            if (typeof record.code !== 'number') return null;
            return { type: 'error', code: record.code };
        case 'time':
            if (typeof record.state !== 'number') return null;
            return {
                type: 'time',
                currentTime: finiteOrZero(record.currentTime),
                duration: finiteOrZero(record.duration),
                state: record.state,
            };
        default:
            return null;
    }
}

/** ホストページへ送る制御コマンドを構築する。seek の秒数は 0 以上の有限値へ丸める。 */
export function buildEmbedCommand(cmd: 'play' | 'pause' | 'unmute'): EmbedCommand;
export function buildEmbedCommand(cmd: 'seek', seconds: number): EmbedCommand;
export function buildEmbedCommand(cmd: 'play' | 'pause' | 'seek' | 'unmute', seconds?: number): EmbedCommand {
    if (cmd === 'seek') {
        const raw = typeof seconds === 'number' && Number.isFinite(seconds) ? seconds : 0;
        return { source: 'ux-embed-cmd', cmd: 'seek', seconds: Math.max(0, raw) };
    }
    return { source: 'ux-embed-cmd', cmd };
}
