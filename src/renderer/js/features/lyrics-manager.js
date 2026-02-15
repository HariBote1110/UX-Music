import { state, elements } from '../core/state.js';
// --- ▼▼▼ 追加 ▼▼▼ ---
import { showContextMenu } from '../ui/utils.js';
import { startLrcEditor } from './lrc-editor.js'; // あとで作成
// --- ▲▲▲ 追加 ▲▲▲ ---
const electronAPI = window.electronAPI;
const LYRICS_SCROLL_MIN_DURATION_MS = 700;
const LYRICS_SCROLL_MAX_DURATION_MS = 1020;
const LYRICS_SCROLL_MIN_DISTANCE_PX = 6;
let lyricsScrollAnimationFrame = null;
const LYRICS_TRAFFIC_WAVE_BASE_DELAY_MS = 36;
const LYRICS_TRAFFIC_WAVE_STEP_MS = 34;
const LYRICS_TRAFFIC_WAVE_DISTANCE_LIMIT = 28;
const LYRICS_TRAFFIC_WAVE_DISTANCE_DECAY = 0.05;
const LYRICS_TRAFFIC_WAVE_OFFSET_FACTOR = 0.24;
const LYRICS_TRAFFIC_WAVE_MAX_OFFSET_PX = 30;
let lyricsLagPrimeFrame = null;
let lyricsLagRunFrame = null;
let previousActiveLyricsIndex = -1;

/**
 * 曲が再生されたときに歌詞を読み込んで表示するメイン関数
 * @param {object} song - 再生中の曲オブジェクト
 */
export async function loadLyricsForSong(song) {
    clearLyrics();
    state.currentLyrics = null;
    state.currentLyricsType = null; // ★★★ リセット ★★★
    if (!song) return;

    const result = await electronAPI.invoke('get-lyrics', song);
    if (!result) {
        displayNoLyrics();
        // ★★★ TXT/LRCがない場合でもコンテキストメニューを設定 ★★★
        setupLyricsContextMenu(song, null); // type を null で渡す
        return;
    }

    console.log('[Lyrics Debug] 歌詞ファイルが見つかりました:', result);
    state.currentLyricsType = result.type; // ★★★ タイプを設定 ★★★

    if (result.type === 'lrc') {
        const parsedLyrics = parseLRC(result.content);
        console.log('[Lyrics Debug] LRC解析結果:', parsedLyrics);
        if (parsedLyrics && parsedLyrics.length > 0) {
            state.currentLyrics = parsedLyrics;
            renderLyrics(parsedLyrics);
        } else {
            console.error('[Lyrics Debug] LRCの解析後、データが空になりました。');
            state.currentLyricsType = null; // 解析失敗時はタイプをリセット
            displayNoLyrics();
        }
    } else if (result.type === 'txt') {
        renderLyrics(result.content); // state.currentLyrics は null のまま
    }

    // ★★★ コンテキストメニューを設定 ★★★
    setupLyricsContextMenu(song, state.currentLyricsType);
}

// ... (parseLRC, clearLyrics, displayNoLyrics, renderLyrics は変更なし) ...
/**
 * LRC形式の文字列を解析して、時間とテキストのオブジェクトの配列に変換する
 * @param {string} lrcContent - LRCファイルの中身
 * @returns {Array<{time: number, text: string}>}
 */
function parseLRC(lrcContent) {
    const lines = lrcContent.split('\n');
    const lyrics = [];
    const timeRegex = /\[(\d{2})[:.](\d{2})[.](\d{2,3})\]/g;

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
    stopLyricsScrollAnimation();
    stopLyricsLagAnimation();
    previousActiveLyricsIndex = -1;
    elements.lyricsView.innerHTML = '';
    elements.lyricsView.scrollTop = 0;
    // 既存のリスナーがあれば削除 (念のため)
    elements.lyricsView.removeEventListener('contextmenu', handleLyricsContextMenu);
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
    // clearLyrics(); // clearLyrics は loadLyricsForSong の冒頭で呼ばれる
    if (typeof lyrics === 'string') {
        // テキスト歌詞を行ごとに分割し、空行もスペースとして表示
        lyrics.split('\n').forEach(line => {
            const p = document.createElement('p');
            p.textContent = line.trim() === '' ? ' ' : line; // 空行はスペースに
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

function getLyricsVisibleRect(containerRect) {
    const footerHeightRaw = getComputedStyle(document.documentElement).getPropertyValue('--footer-height');
    const footerHeight = Number.parseFloat(footerHeightRaw) || 0;
    if (footerHeight <= 0) {
        return {
            top: containerRect.top,
            bottom: containerRect.bottom,
        };
    }

    const footerTop = window.innerHeight - footerHeight;
    const overlapTop = Math.max(containerRect.top, footerTop);
    const overlapBottom = Math.min(containerRect.bottom, window.innerHeight);
    const overlapHeight = Math.max(0, overlapBottom - overlapTop);
    const visibleBottom = containerRect.bottom - overlapHeight;

    return {
        top: containerRect.top,
        bottom: Math.max(containerRect.top, visibleBottom),
    };
}

function getLyricsScrollTarget(container, lineElement) {
    const containerRect = container.getBoundingClientRect();
    const lineRect = lineElement.getBoundingClientRect();
    const visibleRect = getLyricsVisibleRect(containerRect);
    const lineCentre = lineRect.top + lineRect.height / 2;
    const visibleCentre = visibleRect.top + (visibleRect.bottom - visibleRect.top) / 2;
    const desiredTop = container.scrollTop + (lineCentre - visibleCentre);
    const maxTop = Math.max(0, container.scrollHeight - container.clientHeight);
    return Math.min(maxTop, Math.max(0, desiredTop));
}

function stopLyricsScrollAnimation() {
    if (lyricsScrollAnimationFrame) {
        cancelAnimationFrame(lyricsScrollAnimationFrame);
        lyricsScrollAnimationFrame = null;
    }
}

function stopLyricsLagAnimation(reset = true) {
    if (lyricsLagPrimeFrame) {
        cancelAnimationFrame(lyricsLagPrimeFrame);
        lyricsLagPrimeFrame = null;
    }
    if (lyricsLagRunFrame) {
        cancelAnimationFrame(lyricsLagRunFrame);
        lyricsLagRunFrame = null;
    }
    if (!reset || !elements.lyricsView) {
        return;
    }

    elements.lyricsView.querySelectorAll('p[data-index]').forEach(line => {
        line.classList.remove('lag-prime');
        line.style.removeProperty('--line-lag-delay');
        line.style.removeProperty('--line-lag-offset');
    });
}

// イージング 23 番相当（easeOutBack）
function easeOutBack23(progress) {
    const overshoot = 1.70158;
    const weight = overshoot + 1;
    const shifted = progress - 1;
    return 1 + weight * Math.pow(shifted, 3) + overshoot * Math.pow(shifted, 2);
}

function clamp(value, min, max) {
    return Math.min(max, Math.max(min, value));
}

function getLyricsIndexFromElement(line) {
    return Number.parseInt(line.dataset.index || '', 10);
}

function applyTrafficWaveLag(activeIndex, distance) {
    const reducedMotionQuery = window.matchMedia('(prefers-reduced-motion: reduce)');
    if (reducedMotionQuery.matches || !elements.lyricsView) {
        stopLyricsLagAnimation();
        return;
    }

    const allLines = Array.from(elements.lyricsView.querySelectorAll('p[data-index]'));
    if (allLines.length === 0) {
        return;
    }

    stopLyricsLagAnimation(false);

    const direction = activeIndex >= previousActiveLyricsIndex ? 1 : -1;
    const peakOffset = clamp(
        distance * LYRICS_TRAFFIC_WAVE_OFFSET_FACTOR,
        -LYRICS_TRAFFIC_WAVE_MAX_OFFSET_PX,
        LYRICS_TRAFFIC_WAVE_MAX_OFFSET_PX,
    );

    if (Math.abs(peakOffset) < 0.5) {
        return;
    }

    const targetLines = allLines
        .map(line => ({ line, index: getLyricsIndexFromElement(line) }))
        .filter(item => Number.isFinite(item.index))
        .filter(item => Math.abs(item.index - activeIndex) <= LYRICS_TRAFFIC_WAVE_DISTANCE_LIMIT)
        .sort((a, b) => (direction >= 0 ? a.index - b.index : b.index - a.index));

    if (targetLines.length === 0) {
        return;
    }

    targetLines.forEach((item, order) => {
        const distanceFromActive = Math.abs(item.index - activeIndex);
        const attenuation = clamp(1 - distanceFromActive * LYRICS_TRAFFIC_WAVE_DISTANCE_DECAY, 0.24, 1);
        const activeAttenuation = distanceFromActive === 0 ? 0.42 : 1;
        const lineOffset = peakOffset * attenuation * activeAttenuation;
        const staggerDelay = Math.pow(order, 1.12) * LYRICS_TRAFFIC_WAVE_STEP_MS;
        const lineDelay = LYRICS_TRAFFIC_WAVE_BASE_DELAY_MS + staggerDelay;

        item.line.classList.add('lag-prime');
        item.line.style.setProperty('--line-lag-delay', `${lineDelay}ms`);
        item.line.style.setProperty('--line-lag-offset', `${lineOffset.toFixed(3)}px`);
    });

    lyricsLagPrimeFrame = requestAnimationFrame(() => {
        targetLines.forEach(item => item.line.classList.remove('lag-prime'));
        lyricsLagRunFrame = requestAnimationFrame(() => {
            targetLines.forEach(item => item.line.style.setProperty('--line-lag-offset', '0px'));
            lyricsLagRunFrame = null;
        });
        lyricsLagPrimeFrame = null;
    });
}

function getLyricsScrollDuration(distance) {
    const adaptiveDuration = LYRICS_SCROLL_MIN_DURATION_MS + Math.abs(distance) * 0.42;
    return clamp(adaptiveDuration, LYRICS_SCROLL_MIN_DURATION_MS, LYRICS_SCROLL_MAX_DURATION_MS);
}

function animateLyricsScrollTo(container, targetTop, activeIndex) {
    const reducedMotionQuery = window.matchMedia('(prefers-reduced-motion: reduce)');
    if (reducedMotionQuery.matches) {
        stopLyricsScrollAnimation();
        stopLyricsLagAnimation();
        container.scrollTop = targetTop;
        return;
    }

    stopLyricsScrollAnimation();

    const startTop = container.scrollTop;
    const distance = targetTop - startTop;
    if (Math.abs(distance) <= LYRICS_SCROLL_MIN_DISTANCE_PX) {
        container.scrollTop = targetTop;
        stopLyricsLagAnimation();
        return;
    }

    applyTrafficWaveLag(activeIndex, distance);

    const scrollDuration = getLyricsScrollDuration(distance);
    const startTime = performance.now();
    const step = (now) => {
        const elapsed = now - startTime;
        const progress = Math.min(1, elapsed / scrollDuration);
        const easedProgress = easeOutBack23(progress);
        container.scrollTop = startTop + distance * easedProgress;

        if (progress < 1) {
            lyricsScrollAnimationFrame = requestAnimationFrame(step);
            return;
        }

        container.scrollTop = targetTop;
        lyricsScrollAnimationFrame = null;
    };

    lyricsScrollAnimationFrame = requestAnimationFrame(step);
}


// --- ▼▼▼ コンテキストメニュー関連の関数を追加 ▼▼▼ ---

let currentContextMenuSong = null;
let currentContextMenuType = null;

/**
 * 歌詞表示エリアにコンテキストメニューを設定する
 * @param {object} song - 現在の曲オブジェクト
 * @param {'txt'|'lrc'|null} type - 現在表示中の歌詞タイプ
 */
function setupLyricsContextMenu(song, type) {
    currentContextMenuSong = song;
    currentContextMenuType = type;
    // 既存のリスナーを削除してから追加し直す
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

    // 現在曲があり、かつLRCではない場合（TXTまたは歌詞なしの場合）にメニューを表示
    if (currentContextMenuSong && currentContextMenuType !== 'lrc') {
        menuItems.push({
            label: '同期歌詞を作成...',
            action: () => {
                // lrc-editor.js (未作成) の関数を呼び出す
                startLrcEditor(currentContextMenuSong);
                console.log('同期歌詞エディタを開始 (予定):', currentContextMenuSong.title);
            }
        });
    }

    // 他のメニュー項目（例：歌詞をコピーなど）もここに追加可能

    if (menuItems.length > 0) {
        showContextMenu(event.pageX, event.pageY, menuItems);
    }
}
// --- ▲▲▲ ここまで追加 ▲▲▲ ---

/**
 * 再生時間に合わせてLRC歌詞を更新・同期する
 * @param {number} currentTime - 現在の再生時間 (秒)
 */
export function updateSyncedLyrics(currentTime) {
    const lyricsContainer = document.getElementById('lyrics-container');
    // ★★★ state.currentLyricsType === 'lrc' もチェック ★★★
    if (!state.currentLyrics || state.currentLyricsType !== 'lrc' || !lyricsContainer || !lyricsContainer.classList.contains('active')) {
        return;
    }

    let currentIndex = -1;
    for (let i = state.currentLyrics.length - 1; i >= 0; i--) {
        if (currentTime >= state.currentLyrics[i].time) {
            currentIndex = i;
            break;
        }
    }

    const activeLine = elements.lyricsView.querySelector('p.active');
    // 現在アクティブな行が正しい場合は何もしない
    if (activeLine && parseInt(activeLine.dataset.index, 10) === currentIndex) {
        return;
    }

    // すべてのアクティブクラスを削除
    elements.lyricsView.querySelectorAll('p.active').forEach(p => p.classList.remove('active'));

    if (currentIndex !== -1) {
        const newLine = elements.lyricsView.querySelector(`p[data-index="${currentIndex}"]`);
        if (newLine) {
            newLine.classList.add('active');
            const targetTop = getLyricsScrollTarget(elements.lyricsView, newLine);
            if (Math.abs(elements.lyricsView.scrollTop - targetTop) > 1) {
                animateLyricsScrollTo(elements.lyricsView, targetTop, currentIndex);
            }
        }
        previousActiveLyricsIndex = currentIndex;
    } else {
        // 曲の冒頭など、まだどの行もアクティブでない場合は一番上にスクロール
        stopLyricsScrollAnimation();
        stopLyricsLagAnimation();
        elements.lyricsView.scrollTop = 0;
        previousActiveLyricsIndex = -1;
    }
}
