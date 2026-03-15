import { state, elements } from '../core/state.js';
import { showContextMenu } from '../ui/utils.js';
import { startLrcEditor } from './lrc-editor.js';

const electronAPI = window.electronAPI;

const LYRICS_MOTION_ANCHOR_RATIO = 0.35;
const LYRICS_MOTION_DELAY_STEP_MS = 40;
const LYRICS_MOTION_DURATION_MS = 800;
const LYRICS_MOTION_LINE_HEIGHT_RATIO = 0.13;
const LYRICS_MOTION_LINE_HEIGHT_MIN_PX = 58;
const LYRICS_MOTION_LINE_HEIGHT_MAX_PX = 96;

let currentContextMenuSong = null;
let currentContextMenuType = null;
let currentAnimatedLyricsIndex = -1;
let lyricsRelayoutFrame = null;
let isLyricsMotionListenerBound = false;
let lyricsContainerObserver = null;
let lyricsLineElements = [];
let lastResolvedLyricsIndex = -1;

/**
 * 曲が再生されたときに歌詞を読み込んで表示するメイン関数
 * @param {object} song - 再生中の曲オブジェクト
 */
export async function loadLyricsForSong(song) {
    clearLyrics();
    state.currentLyrics = null;
    state.currentLyricsType = null;
    if (!song) return;

    const result = await electronAPI.invoke('get-lyrics', song);
    if (!result) {
        displayNoLyrics();
        setupLyricsContextMenu(song, null);
        return;
    }

    console.log('[Lyrics Debug] 歌詞ファイルが見つかりました:', result);
    state.currentLyricsType = result.type;

    if (result.type === 'lrc') {
        const parsedLyrics = parseLRC(result.content);
        console.log('[Lyrics Debug] LRC解析結果:', parsedLyrics);
        if (parsedLyrics && parsedLyrics.length > 0) {
            state.currentLyrics = parsedLyrics;
            renderLyrics(parsedLyrics);
        } else {
            console.error('[Lyrics Debug] LRCの解析後、データが空になりました。');
            state.currentLyricsType = null;
            displayNoLyrics();
        }
    } else if (result.type === 'txt') {
        renderLyrics(result.content);
    }

    setupLyricsContextMenu(song, state.currentLyricsType);
}

/**
 * LRC形式の文字列を解析して、時間とテキストのオブジェクトの配列に変換する
 * @param {string} lrcContent - LRCファイルの中身
 * @returns {Array<{time: number, text: string}>}
 */
function parseLRC(lrcContent) {
    const lines = lrcContent.split('\n');
    const lyrics = [];
    const timeRegex = /\[(\d{2})[:.](\d{2})[.](\d{2,3})\]/g;

    lines.forEach((line, sourceLine) => {
        const text = line.replace(timeRegex, '').trim();
        const matches = [...line.matchAll(timeRegex)];

        if (matches.length > 0) {
            matches.forEach(match => {
                const minutes = Number.parseInt(match[1], 10);
                const seconds = Number.parseInt(match[2], 10);
                const milliseconds = Number.parseInt(match[3].padEnd(3, '0'), 10);
                const time = minutes * 60 + seconds + milliseconds / 1000;

                lyrics.push({ time, text: text || ' ', sourceLine });
            });
        }
    });

    return lyrics.sort((a, b) => (a.time - b.time) || (a.sourceLine - b.sourceLine));
}

/**
 * 歌詞表示エリアをクリアする
 */
function clearLyrics() {
    stopLyricsRelayout();
    currentAnimatedLyricsIndex = -1;
    lastResolvedLyricsIndex = -1;
    lyricsLineElements = [];
    elements.lyricsView.innerHTML = '';
    elements.lyricsView.scrollTop = 0;
    elements.lyricsView.classList.remove('lyrics-mode-lrc', 'lyrics-mode-txt');
    elements.lyricsView.removeEventListener('contextmenu', handleLyricsContextMenu);
}

/**
 * 「歌詞はありません」というメッセージを表示する
 */
function displayNoLyrics() {
    elements.lyricsView.classList.remove('lyrics-mode-lrc', 'lyrics-mode-txt');
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
    if (typeof lyrics === 'string') {
        elements.lyricsView.classList.add('lyrics-mode-txt');
        elements.lyricsView.classList.remove('lyrics-mode-lrc');
        lyrics.split('\n').forEach((line, index) => {
            const p = document.createElement('p');
            p.textContent = line.trim() === '' ? ' ' : line;
            p.dataset.sourceLine = String(index);
            if (index > 0) {
                p.classList.add('line-break');
            }
            elements.lyricsView.appendChild(p);
        });
        lyricsLineElements = [];
        return;
    }

    elements.lyricsView.classList.add('lyrics-mode-lrc');
    elements.lyricsView.classList.remove('lyrics-mode-txt');
    console.log(`[Lyrics Debug] ${lyrics.length}行のLRC歌詞を描画します。`);

    let previousSourceLine = null;
    lyrics.forEach((line, index) => {
        const p = document.createElement('p');
        p.textContent = line.text;
        p.dataset.index = String(index);
        if (Number.isFinite(line.sourceLine)) {
            p.dataset.sourceLine = String(line.sourceLine);
        }
        if (index > 0) {
            const sameSourceLine = Number.isFinite(line.sourceLine)
                && previousSourceLine !== null
                && line.sourceLine === previousSourceLine;
            p.classList.add(sameSourceLine ? 'line-continuation' : 'line-break');
        }
        elements.lyricsView.appendChild(p);
        previousSourceLine = Number.isFinite(line.sourceLine) ? line.sourceLine : previousSourceLine;
    });

    lyricsLineElements = Array.from(elements.lyricsView.querySelectorAll('p[data-index]'));
    lastResolvedLyricsIndex = -1;

    ensureLyricsMotionListeners();
    applyLyricsMotionByIndex(-1, true);
}

function clamp(value, min, max) {
    return Math.min(max, Math.max(min, value));
}

function getLineHeightPx(container) {
    const responsiveHeight = container.clientHeight * LYRICS_MOTION_LINE_HEIGHT_RATIO;
    return clamp(responsiveHeight, LYRICS_MOTION_LINE_HEIGHT_MIN_PX, LYRICS_MOTION_LINE_HEIGHT_MAX_PX);
}

function stopLyricsRelayout() {
    if (!lyricsRelayoutFrame) {
        return;
    }
    cancelAnimationFrame(lyricsRelayoutFrame);
    lyricsRelayoutFrame = null;
}

function scheduleLyricsRelayout(immediate = true) {
    stopLyricsRelayout();
    lyricsRelayoutFrame = requestAnimationFrame(() => {
        lyricsRelayoutFrame = null;
        applyLyricsMotionByIndex(currentAnimatedLyricsIndex, immediate);
    });
}

function ensureLyricsMotionListeners() {
    if (!isLyricsMotionListenerBound) {
        window.addEventListener('resize', () => {
            if (!elements.lyricsView?.classList.contains('lyrics-mode-lrc')) {
                return;
            }
            scheduleLyricsRelayout(true);
        });
        isLyricsMotionListenerBound = true;
    }

    if (lyricsContainerObserver) {
        return;
    }

    const lyricsContainer = document.getElementById('lyrics-container');
    if (!lyricsContainer) {
        return;
    }

    lyricsContainerObserver = new MutationObserver(() => {
        if (!lyricsContainer.classList.contains('active')) {
            return;
        }
        if (!elements.lyricsView?.classList.contains('lyrics-mode-lrc')) {
            return;
        }
        scheduleLyricsRelayout(true);
    });

    lyricsContainerObserver.observe(lyricsContainer, {
        attributes: true,
        attributeFilter: ['class'],
    });
}

function applyLyricsMotionByIndex(activeIndex, immediate = false) {
    if (!elements.lyricsView || !elements.lyricsView.classList.contains('lyrics-mode-lrc')) {
        return;
    }

    const lines = lyricsLineElements;
    if (lines.length === 0) {
        return;
    }

    const container = elements.lyricsView;
    const baseIndex = activeIndex >= 0 ? activeIndex : 0;
    const anchorY = container.clientHeight * LYRICS_MOTION_ANCHOR_RATIO;
    const lineHeight = getLineHeightPx(container);
    currentAnimatedLyricsIndex = activeIndex;

    if (immediate || activeIndex < 0 || currentAnimatedLyricsIndex < 0) {
        lines.forEach((line, index) => {
            const isActive = index === activeIndex;
            const offset = index - baseIndex;
            const distanceFromActive = Math.abs(offset);
            const y = anchorY + offset * lineHeight;
            const motionDelay = immediate ? 0 : distanceFromActive * LYRICS_MOTION_DELAY_STEP_MS;
            const motionDuration = immediate ? 0 : LYRICS_MOTION_DURATION_MS;

            line.classList.toggle('active', isActive);
            line.style.setProperty('--line-motion-delay', `${motionDelay}ms`);
            line.style.setProperty('--line-motion-duration', `${motionDuration}ms`);
            line.style.transform = `translate3d(-50%, ${y.toFixed(3)}px, 0) scale(${isActive ? 1 : 0.9})`;
            line.style.opacity = isActive ? '1' : '0.35';
            line.style.filter = isActive ? 'blur(0px)' : 'blur(1.5px)';
            line.style.zIndex = isActive ? '10' : '1';
        });
        currentAnimatedLyricsIndex = activeIndex;
        return;
    }

    const previousIndex = currentAnimatedLyricsIndex;
    const direction = activeIndex > previousIndex ? 1 : -1;

    const updateLine = (index) => {
        const line = lines[index];
        if (!line) return;
        const isActive = index === activeIndex;
        const offset = index - baseIndex;
        const distanceFromActive = Math.abs(offset);
        const y = anchorY + offset * lineHeight;
        const motionDelay = distanceFromActive * LYRICS_MOTION_DELAY_STEP_MS;

        line.classList.toggle('active', isActive);
        line.style.setProperty('--line-motion-delay', `${motionDelay}ms`);
        line.style.setProperty('--line-motion-duration', `${LYRICS_MOTION_DURATION_MS}ms`);
        line.style.transform = `translate3d(-50%, ${y.toFixed(3)}px, 0) scale(${isActive ? 1 : 0.9})`;
        line.style.opacity = isActive ? '1' : '0.35';
        line.style.filter = isActive ? 'blur(0px)' : 'blur(1.5px)';
        line.style.zIndex = isActive ? '10' : '1';
    };

    for (let index = previousIndex; index !== activeIndex; index += direction) {
        updateLine(index);
    }
    updateLine(activeIndex);
    currentAnimatedLyricsIndex = activeIndex;
}

function findLyricsIndexForTime(currentTime) {
    const lyrics = state.currentLyrics;
    if (!Array.isArray(lyrics) || lyrics.length === 0) {
        return -1;
    }

    const lastIndex = lyrics.length - 1;
    if (currentTime < lyrics[0].time) {
        return -1;
    }
    if (currentTime >= lyrics[lastIndex].time) {
        return lastIndex;
    }

    if (lastResolvedLyricsIndex >= 0 && lastResolvedLyricsIndex < lyrics.length) {
        const currentLine = lyrics[lastResolvedLyricsIndex];
        const nextLine = lyrics[lastResolvedLyricsIndex + 1];
        if (currentTime >= currentLine.time && (!nextLine || currentTime < nextLine.time)) {
            return lastResolvedLyricsIndex;
        }
        if (nextLine && currentTime >= nextLine.time) {
            let index = lastResolvedLyricsIndex + 1;
            while (index < lastIndex && currentTime >= lyrics[index + 1].time) {
                index += 1;
            }
            return index;
        }
    }

    let low = 0;
    let high = lastIndex;
    let resolved = -1;

    while (low <= high) {
        const mid = Math.floor((low + high) / 2);
        if (lyrics[mid].time <= currentTime) {
            resolved = mid;
            low = mid + 1;
        } else {
            high = mid - 1;
        }
    }

    return resolved;
}

/**
 * 歌詞表示エリアにコンテキストメニューを設定する
 * @param {object} song - 現在の曲オブジェクト
 * @param {'txt'|'lrc'|null} type - 現在表示中の歌詞タイプ
 */
function setupLyricsContextMenu(song, type) {
    currentContextMenuSong = song;
    currentContextMenuType = type;
    elements.lyricsView.removeEventListener('contextmenu', handleLyricsContextMenu);
    elements.lyricsView.addEventListener('contextmenu', handleLyricsContextMenu);
}

/**
 * コンテキストメニューイベントのハンドラ
 * @param {MouseEvent} event
 */
function handleLyricsContextMenu(event) {
    event.preventDefault();
    const menuItems = [];

    if (currentContextMenuSong) {
        const isLrc = currentContextMenuType === 'lrc';
        menuItems.push({
            label: isLrc ? '同期歌詞を編集...' : '同期歌詞を作成...',
            action: () => {
                startLrcEditor(currentContextMenuSong);
                console.log('同期歌詞エディタを開始:', currentContextMenuSong.title);
            }
        });
    }

    if (menuItems.length > 0) {
        showContextMenu(event.pageX, event.pageY, menuItems);
    }
}

/**
 * 再生時間に合わせてLRC歌詞を更新・同期する
 * @param {number} currentTime - 現在の再生時間 (秒)
 */
export function updateSyncedLyrics(currentTime) {
    const lyricsContainer = document.getElementById('lyrics-container');
    if (!state.currentLyrics || state.currentLyricsType !== 'lrc' || !lyricsContainer || !lyricsContainer.classList.contains('active')) {
        return;
    }

    const currentIndex = findLyricsIndexForTime(currentTime);
    if (currentIndex !== currentAnimatedLyricsIndex) {
        lastResolvedLyricsIndex = currentIndex;
        applyLyricsMotionByIndex(currentIndex, false);
    }
}
