import { state, elements } from './state.js';
const { ipcRenderer } = require('electron');

/**
 * 曲が再生されたときに歌詞を読み込んで表示するメイン関数
 * @param {object} song - 再生中の曲オブジェクト
 */
export async function loadLyricsForSong(song) {
    clearLyrics();
    state.currentLyrics = null;
    if (!song) return;

    const result = await ipcRenderer.invoke('get-lyrics', song);
    if (!result) {
        displayNoLyrics();
        return;
    }

    console.log('[Lyrics Debug] 歌詞ファイルが見つかりました:', result);

    if (result.type === 'lrc') {
        const parsedLyrics = parseLRC(result.content);
        
        console.log('[Lyrics Debug] LRC解析結果:', parsedLyrics);

        if (parsedLyrics && parsedLyrics.length > 0) {
            state.currentLyrics = parsedLyrics;
            renderLyrics(parsedLyrics);
        } else {
            console.error('[Lyrics Debug] LRCの解析後、データが空になりました。');
            displayNoLyrics();
        }
    } else if (result.type === 'txt') {
        renderLyrics(result.content);
    }
}

/**
 * LRC形式の文字列を解析して、時間とテキストのオブジェクトの配列に変換する
 * @param {string} lrcContent - LRCファイルの中身
 * @returns {Array<{time: number, text: string}>}
 */
function parseLRC(lrcContent) {
    const lines = lrcContent.split('\n');
    const lyrics = [];
    // ★★★ ここからが修正箇所です ★★★
    // 区切り文字として ':' または '.' の両方を許可する正規表現
    const timeRegex = /\[(\d{2})[:.](\d{2})[.](\d{2,3})\]/g;
    // ★★★ ここまでが修正箇所です ★★★

    lines.forEach(line => {
        const text = line.replace(timeRegex, '').trim();
        const matches = [...line.matchAll(timeRegex)];
        
        if (matches.length > 0) {
            matches.forEach(match => {
                const minutes = parseInt(match[1], 10);
                const seconds = parseInt(match[2], 10);
                const milliseconds = parseInt(match[3].padEnd(3, '0'), 10);
                const time = minutes * 60 + seconds + milliseconds / 1000;
                
                lyrics.push({ time, text: text || ' ' });
            });
        }
    });

    return lyrics.sort((a, b) => a.time - b.time);
}

/**
 * 歌詞表示エリアをクリアする
 */
function clearLyrics() {
    elements.lyricsView.innerHTML = '';
}

/**
 * 「歌詞はありません」というメッセージを表示する
 */
function displayNoLyrics() {
    elements.lyricsView.innerHTML = `<p class="no-lyrics">
        曲名と同じ名前の<br>
        .lrc または .txt ファイルが見つかりませんでした。
    </p>`;
}

/**
 * 解析済みの歌詞データをUIに描画する
 * @param {Array|string} lyrics - LRCの配列またはTXTの文字列
 */
function renderLyrics(lyrics) {
    clearLyrics();
    if (typeof lyrics === 'string') {
        lyrics.split('\n').forEach(line => {
            const p = document.createElement('p');
            p.textContent = line || ' ';
            elements.lyricsView.appendChild(p);
        });
    } else {
        console.log(`[Lyrics Debug] ${lyrics.length}行のLRC歌詞を描画します。`);
        lyrics.forEach((line, index) => {
            const p = document.createElement('p');
            p.textContent = line.text;
            p.dataset.index = index;
            elements.lyricsView.appendChild(p);
        });
    }
}

/**
 * 再生時間に合わせてLRC歌詞を更新・同期する
 * @param {number} currentTime - 現在の再生時間 (秒)
 */
export function updateSyncedLyrics(currentTime) {
    if (!state.currentLyrics) return;

    let currentIndex = -1;
    for (let i = state.currentLyrics.length - 1; i >= 0; i--) {
        if (currentTime >= state.currentLyrics[i].time) {
            currentIndex = i;
            break;
        }
    }

    const activeLine = elements.lyricsView.querySelector('p.active');
    if (activeLine && parseInt(activeLine.dataset.index) === currentIndex) {
        return;
    }

    elements.lyricsView.querySelectorAll('p').forEach(p => p.classList.remove('active'));

    if (currentIndex !== -1) {
        const newLine = elements.lyricsView.querySelector(`p[data-index="${currentIndex}"]`);
        if (newLine) {
            newLine.classList.add('active');
            const containerRect = elements.lyricsView.getBoundingClientRect();
            const lineRect = newLine.getBoundingClientRect();
            elements.lyricsView.scrollTop += lineRect.top - containerRect.top - (containerRect.height / 2) + (lineRect.height / 2);
        }
    }
}