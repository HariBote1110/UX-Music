import { state, elements } from '../core/state.js';
// --- ▼▼▼ 追加 ▼▼▼ ---
import { showContextMenu } from '../ui/utils.js';
import { startLrcEditor } from './lrc-editor.js'; // あとで作成
// --- ▲▲▲ 追加 ▲▲▲ ---
const electronAPI = window.electronAPI;
const LYRICS_SCROLL_MIN_DISTANCE_PX = 6;
const LYRICS_TOP_ANCHOR_OFFSET_PX = 26;
let lyricsScrollAnimationFrame = null;
let lyricsScrollTargetTop = null;
let lyricsScrollContainer = null;
let lyricsScrollSwitchEasing = false;
const LYRICS_TRAFFIC_WAVE_BASE_DELAY_MS = 84;
const LYRICS_TRAFFIC_WAVE_BASE_DURATION_MS = 760;
const LYRICS_TRAFFIC_WAVE_MIN_DURATION_MS = 300;
const LYRICS_TRAFFIC_WAVE_SPEED_CURVE_EXPONENT = 0.84;
const LYRICS_TRAFFIC_WAVE_DISTANCE_LIMIT = 14;
const LYRICS_TRAFFIC_WAVE_DISTANCE_DECAY = 0.07;
const LYRICS_TRAFFIC_WAVE_OFFSET_FACTOR = 0.22;
const LYRICS_TRAFFIC_WAVE_MAX_OFFSET_PX = 22;
let lyricsLagPrimeFrame = null;
let lyricsLagRunFrame = null;

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

    lines.forEach((line, sourceLine) => {
        const text = line.replace(timeRegex, '').trim();
        const matches = [...line.matchAll(timeRegex)];

        if (matches.length > 0) {
            matches.forEach(match => {
                const minutes = parseInt(match[1], 10);
                const seconds = parseInt(match[2], 10);
                const milliseconds = parseInt(match[3].padEnd(3, '0'), 10);
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
    stopLyricsScrollAnimation();
    stopLyricsLagAnimation();
    elements.lyricsView.innerHTML = '';
    elements.lyricsView.scrollTop = 0;
    elements.lyricsView.classList.remove('lyrics-mode-lrc', 'lyrics-mode-txt');
    // 既存のリスナーがあれば削除 (念のため)
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
    // clearLyrics(); // clearLyrics は loadLyricsForSong の冒頭で呼ばれる
    if (typeof lyrics === 'string') {
        elements.lyricsView.classList.add('lyrics-mode-txt');
        elements.lyricsView.classList.remove('lyrics-mode-lrc');
        // テキスト歌詞を行ごとに分割し、空行もスペースとして表示
        lyrics.split('\n').forEach((line, index) => {
            const p = document.createElement('p');
            p.textContent = line.trim() === '' ? ' ' : line; // 空行はスペースに
            p.dataset.sourceLine = String(index);
            if (index > 0) {
                p.classList.add('line-break');
            }
            elements.lyricsView.appendChild(p);
        });
    } else {
        elements.lyricsView.classList.add('lyrics-mode-lrc');
        elements.lyricsView.classList.remove('lyrics-mode-txt');
        console.log(`[Lyrics Debug] ${lyrics.length}行のLRC歌詞を描画します。`);
        let previousSourceLine = null;
        lyrics.forEach((line, index) => {
            const p = document.createElement('p');
            p.textContent = line.text;
            p.dataset.index = index;
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
    const lineTop = lineRect.top;
    const visibleTop = visibleRect.top + LYRICS_TOP_ANCHOR_OFFSET_PX;
    const desiredTop = container.scrollTop + (lineTop - visibleTop);
    const maxTop = Math.max(0, container.scrollHeight - container.clientHeight);
    return Math.min(maxTop, Math.max(0, desiredTop));
}

function stopLyricsScrollAnimation() {
    if (lyricsScrollAnimationFrame) {
        cancelAnimationFrame(lyricsScrollAnimationFrame);
        lyricsScrollAnimationFrame = null;
    }
    lyricsScrollTargetTop = null;
    lyricsScrollContainer = null;
    lyricsScrollSwitchEasing = false;
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
        line.style.removeProperty('--line-lag-duration');
        line.style.removeProperty('--line-lag-offset');
    });
}

// 立ち上がりを速くしつつ終端で滑らかに減速する ease-out
function easeOutCubic(progress) {
    return 1 - Math.pow(1 - progress, 3);
}

function clamp(value, min, max) {
    return Math.min(max, Math.max(min, value));
}

function getLyricsIndexFromElement(line) {
    return Number.parseInt(line.dataset.index || '', 10);
}

function getDisplayedLyricsIndex(container) {
    if (!container) return -1;

    const containerRect = container.getBoundingClientRect();
    const visibleRect = getLyricsVisibleRect(containerRect);
    const anchorTop = visibleRect.top + LYRICS_TOP_ANCHOR_OFFSET_PX;
    const lines = Array.from(container.querySelectorAll('p[data-index]'));
    if (lines.length === 0) return -1;

    let closestIndex = -1;
    let closestDistance = Number.POSITIVE_INFINITY;

    lines.forEach(line => {
        const index = getLyricsIndexFromElement(line);
        if (!Number.isFinite(index)) return;
        const rect = line.getBoundingClientRect();
        if (rect.bottom < visibleRect.top || rect.top > visibleRect.bottom) {
            return;
        }

        const distance = Math.abs(rect.top - anchorTop);
        if (distance < closestDistance) {
            closestDistance = distance;
            closestIndex = index;
        }
    });

    return closestIndex;
}

function getVisibleLyricsLineCount(container) {
    if (!container) return 0;

    const containerRect = container.getBoundingClientRect();
    const visibleRect = getLyricsVisibleRect(containerRect);
    const lines = Array.from(container.querySelectorAll('p[data-index]'));

    return lines.reduce((count, line) => {
        const rect = line.getBoundingClientRect();
        const intersects = rect.bottom >= visibleRect.top && rect.top <= visibleRect.bottom;
        return intersects ? count + 1 : count;
    }, 0);
}

function applyTrafficWaveLag(distance) {
    const reducedMotionQuery = window.matchMedia('(prefers-reduced-motion: reduce)');
    if (reducedMotionQuery.matches) {
        stopLyricsLagAnimation();
        return;
    }

    if (!elements.lyricsView) {
        return;
    }

    const baseIndex = getDisplayedLyricsIndex(elements.lyricsView);
    if (baseIndex === -1) {
        return;
    }

    const direction = distance >= 0 ? 1 : -1;
    const visibleLineCount = getVisibleLyricsLineCount(elements.lyricsView);
    const sparseViewFactor = clamp((3 - visibleLineCount) / 2, 0, 1);
    const effectiveBaseDelay = clamp(
        LYRICS_TRAFFIC_WAVE_BASE_DELAY_MS * (1 - sparseViewFactor * 0.62),
        18,
        LYRICS_TRAFFIC_WAVE_BASE_DELAY_MS,
    );
    const effectiveBaseDuration = clamp(
        LYRICS_TRAFFIC_WAVE_BASE_DURATION_MS * (1 - sparseViewFactor * 0.24),
        460,
        LYRICS_TRAFFIC_WAVE_BASE_DURATION_MS,
    );
    const effectiveMinDuration = clamp(
        LYRICS_TRAFFIC_WAVE_MIN_DURATION_MS * (1 - sparseViewFactor * 0.2),
        210,
        LYRICS_TRAFFIC_WAVE_MIN_DURATION_MS,
    );
    const peakOffset = clamp(
        distance * LYRICS_TRAFFIC_WAVE_OFFSET_FACTOR,
        -LYRICS_TRAFFIC_WAVE_MAX_OFFSET_PX,
        LYRICS_TRAFFIC_WAVE_MAX_OFFSET_PX,
    ) * (1 - sparseViewFactor * 0.35);
    if (Math.abs(peakOffset) < 0.5) {
        return;
    }

    stopLyricsLagAnimation(false);

    const targetLines = Array.from(elements.lyricsView.querySelectorAll('p[data-index]'))
        .map(line => ({ line, index: getLyricsIndexFromElement(line) }))
        .filter(item => Number.isFinite(item.index))
        .filter(item => direction > 0 ? item.index >= baseIndex : item.index <= baseIndex)
        .filter(item => Math.abs(item.index - baseIndex) <= LYRICS_TRAFFIC_WAVE_DISTANCE_LIMIT)
        .sort((a, b) => (direction > 0 ? a.index - b.index : b.index - a.index));

    if (targetLines.length === 0) {
        return;
    }

    targetLines.forEach(item => {
        const distanceFromBase = Math.abs(item.index - baseIndex);
        const distanceRatio = clamp(distanceFromBase / LYRICS_TRAFFIC_WAVE_DISTANCE_LIMIT, 0, 1);
        const speedFactor = Math.pow(distanceRatio, LYRICS_TRAFFIC_WAVE_SPEED_CURVE_EXPONENT);
        const attenuation = clamp(1 - distanceFromBase * LYRICS_TRAFFIC_WAVE_DISTANCE_DECAY, 0.24, 1);
        const anchorAttenuation = distanceFromBase === 0 ? 0.44 : 1;
        const lineOffset = peakOffset * attenuation * anchorAttenuation;
        const lineDelay = clamp(
            effectiveBaseDelay * (1 - speedFactor),
            0,
            effectiveBaseDelay,
        );
        const lineDuration = clamp(
            effectiveBaseDuration - (effectiveBaseDuration - effectiveMinDuration) * speedFactor,
            effectiveMinDuration,
            effectiveBaseDuration,
        );

        item.line.classList.add('lag-prime');
        item.line.style.setProperty('--line-lag-delay', `${lineDelay}ms`);
        item.line.style.setProperty('--line-lag-duration', `${lineDuration}ms`);
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

function animateLyricsScrollTo(container, targetTop, options = {}) {
    const { triggerLag = false, switchEasing = false } = options;
    const reducedMotionQuery = window.matchMedia('(prefers-reduced-motion: reduce)');
    const maxTop = Math.max(0, container.scrollHeight - container.clientHeight);
    const clampedTargetTop = Math.min(maxTop, Math.max(0, targetTop));

    if (reducedMotionQuery.matches) {
        stopLyricsScrollAnimation();
        stopLyricsLagAnimation();
        container.scrollTop = clampedTargetTop;
        return;
    }

    const distance = clampedTargetTop - container.scrollTop;
    if (Math.abs(distance) <= 0.35) {
        container.scrollTop = clampedTargetTop;
        lyricsScrollTargetTop = clampedTargetTop;
        return;
    }

    if (triggerLag && Math.abs(distance) > LYRICS_SCROLL_MIN_DISTANCE_PX) {
        applyTrafficWaveLag(distance);
    }

    lyricsScrollContainer = container;
    lyricsScrollTargetTop = clampedTargetTop;
    if (switchEasing) {
        lyricsScrollSwitchEasing = true;
    } else if (!lyricsScrollAnimationFrame) {
        lyricsScrollSwitchEasing = false;
    }

    if (lyricsScrollAnimationFrame) {
        return;
    }

    const step = () => {
        if (!lyricsScrollContainer || lyricsScrollTargetTop === null) {
            lyricsScrollAnimationFrame = null;
            return;
        }

        const delta = lyricsScrollTargetTop - lyricsScrollContainer.scrollTop;
        if (Math.abs(delta) <= 0.35) {
            lyricsScrollContainer.scrollTop = lyricsScrollTargetTop;
            lyricsScrollAnimationFrame = null;
            lyricsScrollSwitchEasing = false;
            return;
        }

        const distanceRatio = clamp(Math.abs(delta) / 260, 0, 1);
        const easedDistanceRatio = easeOutCubic(distanceRatio);
        const followStrength = lyricsScrollSwitchEasing
            ? 0.06 + easedDistanceRatio * 0.17
            : 0.09 + distanceRatio * 0.13;
        lyricsScrollContainer.scrollTop += delta * followStrength;
        lyricsScrollAnimationFrame = requestAnimationFrame(step);
    };

    lyricsScrollAnimationFrame = requestAnimationFrame(step);
}

function setActiveLyricsLineByIndex(index) {
    elements.lyricsView.querySelectorAll('p.active').forEach(p => p.classList.remove('active'));
    if (index === -1) return;
    const targetLine = elements.lyricsView.querySelector(`p[data-index="${index}"]`);
    if (targetLine) {
        targetLine.classList.add('active');
    }
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
    const activeIndex = activeLine ? parseInt(activeLine.dataset.index, 10) : -1;

    if (currentIndex !== -1) {
        const currentLine = elements.lyricsView.querySelector(`p[data-index="${currentIndex}"]`);
        if (!currentLine) return;

        if (activeIndex !== currentIndex) {
            setActiveLyricsLineByIndex(currentIndex);
        }

        const targetTop = getLyricsScrollTarget(elements.lyricsView, currentLine);
        const shouldTriggerLag = activeIndex !== currentIndex;
        if (Math.abs(elements.lyricsView.scrollTop - targetTop) > 0.35) {
            animateLyricsScrollTo(elements.lyricsView, targetTop, {
                triggerLag: shouldTriggerLag,
                switchEasing: shouldTriggerLag,
            });
        }
    } else {
        // 曲の冒頭など、まだどの行もアクティブでない場合は一番上にスクロール
        setActiveLyricsLineByIndex(-1);
        stopLyricsScrollAnimation();
        stopLyricsLagAnimation();
        elements.lyricsView.scrollTop = 0;
    }
}
