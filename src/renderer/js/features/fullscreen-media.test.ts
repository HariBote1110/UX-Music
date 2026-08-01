import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, it, expect } from 'vitest';
import { resolveEmbedContainerId, resolveFullscreenMediaMode } from './fullscreen-media.js';

// このファイルの位置を起点に実マークアップを読む。
// new URL('...', import.meta.url) をリテラルのまま書くと Vite が
// アセット参照として静的に書き換えてしまうため、基準 URL は変数に退避する。
const moduleUrl = import.meta.url;
const readRepoFile = (relativePath: string): string =>
    readFileSync(fileURLToPath(new URL(relativePath, moduleUrl)), 'utf8');

// 期待値はモジュールが公開する定数ではなくリテラルの要素 ID で書く。
// 定数を輸入して突き合わせるとモジュールが自分自身と一致することしか
// 示せず、ID が変わってもテストが追従してしまうため。
const FS_VIDEO_SLOT = 'fs-video-slot';
const SIDEBAR_ARTWORK = 'now-playing-artwork-container';

describe('resolveEmbedContainerId', () => {
    it('embed 非稼働なら移動対象なし（null）', () => {
        expect(resolveEmbedContainerId({ fullscreenOpen: false, embedActive: false })).toBeNull();
        expect(resolveEmbedContainerId({ fullscreenOpen: true, embedActive: false })).toBeNull();
    });

    it('embed 稼働 × フルスクリーン開 → フルスクリーンの映像スロット', () => {
        expect(resolveEmbedContainerId({ fullscreenOpen: true, embedActive: true }))
            .toBe(FS_VIDEO_SLOT);
    });

    it('embed 稼働 × フルスクリーン閉 → サイドバーのアートワークコンテナ', () => {
        expect(resolveEmbedContainerId({ fullscreenOpen: false, embedActive: true }))
            .toBe(SIDEBAR_ARTWORK);
    });
});

describe('resolveFullscreenMediaMode', () => {
    it('embed 稼働中は映像モード', () => {
        expect(resolveFullscreenMediaMode(true)).toBe('video');
    });
    it('embed 非稼働時は静止画ジャケットモード', () => {
        expect(resolveFullscreenMediaMode(false)).toBe('artwork');
    });
});

// resolveEmbedContainerId が返す ID は実際の DOM 要素に解決できて初めて意味を持つ。
// 移動先が実在しなければ embed プレイヤーの付け替えは無言で失敗するため、
// それぞれの ID を「実際にその要素を出力しているマークアップ」に対して検証する。
describe('embed の移動先 ID が実マークアップに存在すること', () => {
    it('サイドバーのアートワークコンテナは index.html に存在する', () => {
        const html = readRepoFile('../../index.html');
        expect(html).toContain(`id="${SIDEBAR_ARTWORK}"`);
    });

    // fs-video-slot は index.html には無く、フルスクリーンオーバーレイを
    // 実行時に組み立てる fullscreen-view.ts の buildOverlay() が生成する。
    // そのため出力元であるソースのマークアップに対して検証する。
    it('フルスクリーンの映像スロットは fullscreen-view.ts が生成するマークアップに存在する', () => {
        const source = readRepoFile('./fullscreen-view.ts');
        expect(source).toContain(`id="${FS_VIDEO_SLOT}"`);
    });
});
