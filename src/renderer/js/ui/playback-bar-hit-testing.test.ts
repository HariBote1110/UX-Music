import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, it, expect } from 'vitest';

// このファイルの位置を起点に実スタイルシートを読む。
// new URL('...', import.meta.url) をリテラルのまま書くと Vite が
// アセット参照として静的に書き換えてしまうため、基準 URL は変数に退避する。
const moduleUrl = import.meta.url;
const readRepoFile = (relativePath: string): string =>
    readFileSync(fileURLToPath(new URL(relativePath, moduleUrl)), 'utf8');

// .playback-bar { ... } の宣言ブロック本体だけを抜き出す。
// 同名セレクタが他のメディアクエリ内に存在しても最初の非メディアブロックを拾えば十分。
const extractPlaybackBarBlock = (css: string): string => {
    const match = css.match(/\.playback-bar\s*\{([^}]*)\}/);
    if (!match) {
        throw new Error('.playback-bar のブロックが layout.css 内に見つからない');
    }
    return match[1];
};

describe('フッター（.playback-bar）の当たり判定', () => {
    it('layout.css の .playback-bar は pointer-events: none を宣言していない', () => {
        const css = readRepoFile('../../styles/layout.css');
        const block = extractPlaybackBarBlock(css);
        expect(block).not.toMatch(/pointer-events\s*:\s*none/);
    });

    it('layout.css の .playback-bar は pointer-events: auto を明示している', () => {
        const css = readRepoFile('../../styles/layout.css');
        const block = extractPlaybackBarBlock(css);
        expect(block).toMatch(/pointer-events\s*:\s*auto/);
    });
});
