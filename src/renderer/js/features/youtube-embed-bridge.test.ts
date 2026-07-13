// youtube-embed-bridge の純粋ロジックのテスト。
// ループバックホストページと親ウィンドウの postMessage プロトコルを検証する。

import { describe, it, expect } from 'vitest';
import {
    parseEmbedHostMessage,
    buildEmbedCommand,
    EMBED_PLAYER_STATE,
} from './youtube-embed-bridge.js';

describe('parseEmbedHostMessage', () => {
    it('ready メッセージを受理する', () => {
        expect(parseEmbedHostMessage({ source: 'ux-embed', type: 'ready' }))
            .toEqual({ type: 'ready' });
    });

    it('state メッセージは数値 state を要求する', () => {
        expect(parseEmbedHostMessage({ source: 'ux-embed', type: 'state', state: 1 }))
            .toEqual({ type: 'state', state: 1 });
        expect(parseEmbedHostMessage({ source: 'ux-embed', type: 'state', state: 'x' })).toBeNull();
    });

    it('error メッセージは数値 code を要求する', () => {
        expect(parseEmbedHostMessage({ source: 'ux-embed', type: 'error', code: 153 }))
            .toEqual({ type: 'error', code: 153 });
        expect(parseEmbedHostMessage({ source: 'ux-embed', type: 'error' })).toBeNull();
    });

    it('time メッセージは currentTime / duration / state を数値で取り込み、非有限値は 0 に丸める', () => {
        expect(parseEmbedHostMessage({
            source: 'ux-embed', type: 'time', currentTime: 12.5, duration: 300, state: 1,
        })).toEqual({ type: 'time', currentTime: 12.5, duration: 300, state: 1 });
        expect(parseEmbedHostMessage({
            source: 'ux-embed', type: 'time', currentTime: NaN, duration: Infinity, state: 2,
        })).toEqual({ type: 'time', currentTime: 0, duration: 0, state: 2 });
    });

    it('source が違う・型が不明・非オブジェクトは null', () => {
        expect(parseEmbedHostMessage({ source: 'other', type: 'ready' })).toBeNull();
        expect(parseEmbedHostMessage({ source: 'ux-embed', type: 'unknown' })).toBeNull();
        expect(parseEmbedHostMessage(null)).toBeNull();
        expect(parseEmbedHostMessage('ready')).toBeNull();
    });
});

describe('buildEmbedCommand', () => {
    it('play / pause コマンドを構築する', () => {
        expect(buildEmbedCommand('play')).toEqual({ source: 'ux-embed-cmd', cmd: 'play' });
        expect(buildEmbedCommand('pause')).toEqual({ source: 'ux-embed-cmd', cmd: 'pause' });
    });

    it('unmute コマンドを構築する（タップ確立後の音出し解除に使う）', () => {
        expect(buildEmbedCommand('unmute')).toEqual({ source: 'ux-embed-cmd', cmd: 'unmute' });
    });

    it('seek は秒数を 0 以上の有限値に丸めて付与する', () => {
        expect(buildEmbedCommand('seek', 42.5))
            .toEqual({ source: 'ux-embed-cmd', cmd: 'seek', seconds: 42.5 });
        expect(buildEmbedCommand('seek', -3))
            .toEqual({ source: 'ux-embed-cmd', cmd: 'seek', seconds: 0 });
        expect(buildEmbedCommand('seek', NaN))
            .toEqual({ source: 'ux-embed-cmd', cmd: 'seek', seconds: 0 });
    });
});

describe('EMBED_PLAYER_STATE', () => {
    it('IFrame Player API の状態コードと一致する', () => {
        expect(EMBED_PLAYER_STATE.ENDED).toBe(0);
        expect(EMBED_PLAYER_STATE.PLAYING).toBe(1);
        expect(EMBED_PLAYER_STATE.PAUSED).toBe(2);
    });
});
