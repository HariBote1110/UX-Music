import { state, elements } from '../core/state.js';
import { showContextMenu } from '../ui/utils.js';
import { showNotification } from '../ui/notification.js';
import { startLrcEditor } from './lrc-editor.js';
import { notifyFullscreenLyricsChange } from './fullscreen-view.js';
import { ClipboardSetText } from '../../wailsjs/runtime/runtime.js';
import type { LrcLine } from './lyrics-translation.js';
import {
    buildJaLrcFileContent,
    buildJaTxtFileContent,
    buildLyricsTranslationPrompt,
    deriveLyricsFileBase,
    mergeLrcWithJaLrc,
    mergeLrcWithJaTxt,
    mergePlainTxtWithJa,
    parseLRC,
    parseNumberedLinesFromPastedText,
} from './lyrics-translation.js';

const electronAPI = window.electronAPI;

/** English lines for the last loaded lyrics (LLM プロンプト用) */
let cachedTranslationPromptLines = [];

/** Go FindLyrics が返すベース名（拡張子なし）。保存ファイル名の基準。 */
let cachedLyricsFileBase = '';

let translationPasteModalWired = false;

const LYRICS_MOTION_ANCHOR_RATIO = 0.35;
const LYRICS_MOTION_DELAY_STEP_MS = 40;
const LYRICS_MOTION_DURATION_MS = 800;
/** 同期歌詞ブロック間（次の p の手前）— 可変行高・折返し・和訳行で重なりを防ぐ */
const LYRICS_LRC_INTER_BLOCK_GAP_PX = 16;

let currentContextMenuSong = null;
let currentContextMenuType = null;
let currentAnimatedLyricsIndex = -1;
let lyricsRelayoutFrame = null;
let isLyricsMotionListenerBound = false;
let lyricsContainerObserver = null;
/** @type {ResizeObserver | null} */
let lyricsViewResizeObserver = null;
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

    const result = await electronAPI.invoke('get-lyrics', song) as Record<string, unknown> | null;
    if (!result) {
        displayNoLyrics();
        setupLyricsContextMenu(song, null);
        return;
    }

    console.log('[Lyrics Debug] 歌詞ファイルが見つかりました:', result);
    const resultType = result.type as string | undefined;
    const resultContent = result.content as string | undefined;
    const resultLyricsFileBase = result.lyricsFileBase as string | undefined;
    const resultTranslationContent = result.translationContent as string | undefined;
    const resultTranslationFormat = result.translationFormat as string | undefined;

    state.currentLyricsType = resultType || null;
    cachedLyricsFileBase = resultLyricsFileBase?.trim()
        ? resultLyricsFileBase.trim()
        : deriveLyricsFileBase(song);

    if (resultType === 'lrc') {
        let parsedLyrics = parseLRC(resultContent || '');
        const trans = resultTranslationContent?.trim() || '';
        if (trans) {
            if (resultTranslationFormat === 'lrc') {
                parsedLyrics = mergeLrcWithJaLrc(parsedLyrics, parseLRC(trans));
            } else {
                parsedLyrics = mergeLrcWithJaTxt(parsedLyrics, trans);
            }
        }
        console.log('[Lyrics Debug] LRC解析結果:', parsedLyrics);
        if (parsedLyrics && parsedLyrics.length > 0) {
            state.currentLyrics = parsedLyrics;
            cachedTranslationPromptLines = parsedLyrics.map(l => l.text);
            renderLyrics(parsedLyrics);
        } else {
            console.error('[Lyrics Debug] LRCの解析後、データが空になりました。');
            state.currentLyricsType = null;
            displayNoLyrics();
        }
    } else if (resultType === 'txt') {
        const trans = resultTranslationContent?.trim() || '';
        if (trans) {
            const merged = mergePlainTxtWithJa(resultContent || '', trans);
            cachedTranslationPromptLines = merged.map(l => l.text);
            state.currentLyrics = null;
            renderLyrics(merged);
        } else {
            cachedTranslationPromptLines = (resultContent || '').split('\n');
            renderLyrics(resultContent || '');
        }
    }

    setupLyricsContextMenu(song, state.currentLyricsType);
    notifyFullscreenLyricsChange();
}

function isLrcLineArray(lyrics) {
    return Array.isArray(lyrics) && lyrics.length > 0 && typeof lyrics[0].time === 'number';
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
    elements.lyricsView.classList.remove('lyrics-mode-lrc', 'lyrics-mode-txt', 'lyrics-mode-bilingual');
    elements.lyricsView.removeEventListener('contextmenu', handleLyricsContextMenu);
    cachedLyricsFileBase = '';
    cachedTranslationPromptLines = [];
}

/**
 * 「歌詞はありません」というメッセージを表示する
 */
function displayNoLyrics() {
    cachedTranslationPromptLines = [];
    cachedLyricsFileBase = '';
    elements.lyricsView.classList.remove('lyrics-mode-lrc', 'lyrics-mode-txt', 'lyrics-mode-bilingual');
    elements.lyricsView.innerHTML = `<p class="no-lyrics">
        曲名と同じ名前の<br>
        .lrc または .txt ファイルが見つかりませんでした。
    </p>`;
}

/**
 * 解析済みの歌詞データをUIに描画する
 * @param {Array|string} lyrics - LRCの配列、和訳付きプレーンデータ、または TXT の文字列
 */
function renderLyrics(lyrics) {
    if (typeof lyrics === 'string') {
        elements.lyricsView.classList.add('lyrics-mode-txt');
        elements.lyricsView.classList.remove('lyrics-mode-lrc', 'lyrics-mode-bilingual');
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

    if (Array.isArray(lyrics) && lyrics.length > 0 && !isLrcLineArray(lyrics)) {
        const bilingual = lyrics.some(l => l && l.translation);
        if (bilingual) {
            elements.lyricsView.classList.add('lyrics-mode-bilingual');
        } else {
            elements.lyricsView.classList.remove('lyrics-mode-bilingual');
        }
        elements.lyricsView.classList.add('lyrics-mode-txt');
        elements.lyricsView.classList.remove('lyrics-mode-lrc');
        lyrics.forEach((line, index) => {
            const p = document.createElement('p');
            p.dataset.sourceLine = String(index);
            if (index > 0) {
                p.classList.add('line-break');
            }
            if (bilingual && line.translation) {
                p.classList.add('lyrics-line--bilingual');
                const primary = document.createElement('span');
                primary.className = 'lyrics-line-primary';
                primary.textContent = line.text;
                p.appendChild(primary);
                const tr = document.createElement('span');
                tr.className = 'lyrics-line-translation';
                tr.textContent = line.translation;
                p.appendChild(tr);
            } else {
                p.textContent = line.text;
            }
            elements.lyricsView.appendChild(p);
        });
        lyricsLineElements = [];
        return;
    }

    const bilingualLrc = Array.isArray(lyrics) && lyrics.some(l => l && l.translation);
    if (bilingualLrc) {
        elements.lyricsView.classList.add('lyrics-mode-bilingual');
    } else {
        elements.lyricsView.classList.remove('lyrics-mode-bilingual');
    }

    elements.lyricsView.classList.add('lyrics-mode-lrc');
    elements.lyricsView.classList.remove('lyrics-mode-txt');
    console.log(`[Lyrics Debug] ${lyrics.length}行のLRC歌詞を描画します。`);

    let previousSourceLine = null;
    lyrics.forEach((line, index) => {
        const p = document.createElement('p');
        p.dataset.index = String(index);
        if (bilingualLrc && line.translation) {
            p.classList.add('lyrics-line--bilingual');
            const primary = document.createElement('span');
            primary.className = 'lyrics-line-primary';
            primary.textContent = line.text;
            p.appendChild(primary);
            const tr = document.createElement('span');
            tr.className = 'lyrics-line-translation';
            tr.textContent = line.translation;
            p.appendChild(tr);
        } else {
            p.textContent = line.text;
        }
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

/**
 * 各 LRC 行 p の可視高（折り返し・和訳行を含む）を測定する
 */
function measureLrcBlockHeights(lineElements) {
    return lineElements.map(el => {
        const h = el.getBoundingClientRect().height;
        return Number.isFinite(h) && h > 0 ? h : 1;
    });
}

/**
 * baseIndex 行の先頭 y を anchorY に置き、上下へ実測高＋ギャップで積み上げる
 */
function buildLrcTopPositions(heights, baseIndex, anchorY) {
    const n = heights.length;
    if (n === 0) {
        return [];
    }
    const b = Math.min(Math.max(0, baseIndex), n - 1);
    const tops = new Array(n);
    tops[b] = anchorY;
    for (let i = b + 1; i < n; i += 1) {
        tops[i] = tops[i - 1] + heights[i - 1] + LYRICS_LRC_INTER_BLOCK_GAP_PX;
    }
    for (let i = b - 1; i >= 0; i -= 1) {
        tops[i] = tops[i + 1] - heights[i] - LYRICS_LRC_INTER_BLOCK_GAP_PX;
    }
    return tops;
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

let lyricsResizeThrottleRaf = null;

function ensureLyricsMotionListeners() {
    if (!isLyricsMotionListenerBound) {
        window.addEventListener('resize', () => {
            if (!elements.lyricsView?.classList.contains('lyrics-mode-lrc')) {
                return;
            }
            if (lyricsResizeThrottleRaf != null) return;
            lyricsResizeThrottleRaf = requestAnimationFrame(() => {
                lyricsResizeThrottleRaf = null;
                scheduleLyricsRelayout(true);
            });
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

    if (typeof ResizeObserver !== 'undefined' && elements.lyricsView && !lyricsViewResizeObserver) {
        lyricsViewResizeObserver = new ResizeObserver(() => {
            if (!elements.lyricsView.classList.contains('lyrics-mode-lrc')) {
                return;
            }
            scheduleLyricsRelayout(true);
        });
        lyricsViewResizeObserver.observe(elements.lyricsView);
    }
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
    const motionDuration = immediate ? 0 : LYRICS_MOTION_DURATION_MS;
    const refForDelay = activeIndex >= 0 ? activeIndex : 0;

    lines.forEach((line, index) => {
        line.classList.toggle('active', index === activeIndex);
    });

    const heights = measureLrcBlockHeights(lines);
    const tops = buildLrcTopPositions(heights, baseIndex, anchorY);

    lines.forEach((line, index) => {
        const distanceFromActive = Math.abs(index - refForDelay);
        const y = tops[index];
        const motionDelay = immediate ? 0 : distanceFromActive * LYRICS_MOTION_DELAY_STEP_MS;

        line.style.setProperty('--line-motion-delay', `${motionDelay}ms`);
        line.style.setProperty('--line-motion-duration', `${motionDuration}ms`);
        line.style.setProperty('--lyrics-line-y', `${y.toFixed(3)}px`);
    });

    currentAnimatedLyricsIndex = activeIndex;
}

function findLyricsIndexForTime(currentTime) {
    const lyrics = state.currentLyrics;
    if (!Array.isArray(lyrics) || lyrics.length === 0) {
        lastResolvedLyricsIndex = -1;
        return -1;
    }

    const lastIndex = lyrics.length - 1;
    if (currentTime < lyrics[0].time) {
        lastResolvedLyricsIndex = -1;
        return -1;
    }
    if (currentTime >= lyrics[lastIndex].time) {
        lastResolvedLyricsIndex = lastIndex;
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
            lastResolvedLyricsIndex = index;
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

    lastResolvedLyricsIndex = resolved;
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
        if ((currentContextMenuType === 'lrc' || currentContextMenuType === 'txt')
            && cachedTranslationPromptLines.length > 0) {
            menuItems.push({
                label: '和訳用プロンプトをコピー',
                action: () => {
                    const prompt = buildLyricsTranslationPrompt({
                        title: currentContextMenuSong.title || '',
                        artist: currentContextMenuSong.artist || '',
                        lines: cachedTranslationPromptLines
                    });
                    ClipboardSetText(prompt).catch(() => {
                        if (navigator.clipboard && navigator.clipboard.writeText) {
                            navigator.clipboard.writeText(prompt);
                        }
                    });
                }
            });
        }
        const expectedPasteLines = getExpectedTranslationLineCount();
        if ((currentContextMenuType === 'lrc' || currentContextMenuType === 'txt')
            && expectedPasteLines > 0) {
            menuItems.push({
                label: '和訳の貼り付けで保存...',
                action: () => {
                    openTranslationPasteModal();
                }
            });
        }
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
        applyLyricsMotionByIndex(currentIndex, false);
    }
}

function getExpectedTranslationLineCount() {
    if (currentContextMenuType === 'lrc' && Array.isArray(state.currentLyrics) && state.currentLyrics.length > 0) {
        return state.currentLyrics.length;
    }
    if (currentContextMenuType === 'txt' && cachedTranslationPromptLines.length > 0) {
        return cachedTranslationPromptLines.length;
    }
    return 0;
}

function ensureTranslationPasteModalWired() {
    if (translationPasteModalWired) {
        return;
    }
    const overlay = elements.lyricsTranslationModalOverlay;
    if (!overlay || !elements.lyricsTranslationSaveBtn) {
        return;
    }
    translationPasteModalWired = true;
    elements.lyricsTranslationCancelBtn?.addEventListener('click', () => {
        closeTranslationPasteModal();
    });
    elements.lyricsTranslationSaveBtn.addEventListener('click', () => {
        void onSavePastedTranslation();
    });
    overlay.addEventListener('click', (e) => {
        if (e.target === overlay) {
            closeTranslationPasteModal();
        }
    });
}

function openTranslationPasteModal() {
    ensureTranslationPasteModalWired();
    const n = getExpectedTranslationLineCount();
    if (elements.lyricsTranslationPasteHint) {
        elements.lyricsTranslationPasteHint.textContent = n > 0
            ? `英語歌詞 ${n} 行分の和訳に合わせて貼り付けます。`
            : '';
    }
    if (elements.lyricsTranslationPaste) {
        elements.lyricsTranslationPaste.value = '';
    }
    const overlay = elements.lyricsTranslationModalOverlay;
    if (overlay) {
        overlay.classList.remove('hidden');
        overlay.setAttribute('aria-hidden', 'false');
    }
    setTimeout(() => elements.lyricsTranslationPaste?.focus(), 0);
}

function closeTranslationPasteModal() {
    const overlay = elements.lyricsTranslationModalOverlay;
    if (overlay) {
        overlay.classList.add('hidden');
        overlay.setAttribute('aria-hidden', 'true');
    }
    if (elements.lyricsTranslationPasteHint) {
        elements.lyricsTranslationPasteHint.textContent = '';
    }
}

async function onSavePastedTranslation() {
    const text = elements.lyricsTranslationPaste?.value || '';
    const n = getExpectedTranslationLineCount();
    const parsed = parseNumberedLinesFromPastedText(text, n);
    if (!parsed.ok) {
        const reason = (parsed as { ok: false; reason: string }).reason;
        if (elements.lyricsTranslationPasteHint) {
            elements.lyricsTranslationPasteHint.textContent = reason;
        } else {
            showNotification(reason);
        }
        return;
    }
    const fileBase = cachedLyricsFileBase || deriveLyricsFileBase(currentContextMenuSong);
    if (!fileBase) {
        showNotification('歌詞ファイル名を決められません（曲のパスまたはタイトルが必要です）');
        return;
    }
    let fileName;
    let content;
    if (currentContextMenuType === 'lrc' && state.currentLyrics) {
        fileName = `${fileBase}.ja.lrc`;
        content = buildJaLrcFileContent(state.currentLyrics as LrcLine[], parsed.lines);
    } else if (currentContextMenuType === 'txt') {
        fileName = `${fileBase}.ja.txt`;
        content = buildJaTxtFileContent(parsed.lines, cachedTranslationPromptLines);
    } else {
        showNotification('歌詞の種類を判定できません');
        return;
    }
    const res = await electronAPI.invoke('save-lrc-file', { fileName, content }) as Record<string, unknown> | null;
    if (res && res.success) {
        showNotification('和訳を保存し、再読み込みしました');
        closeTranslationPasteModal();
        if (currentContextMenuSong) {
            await loadLyricsForSong(currentContextMenuSong);
        }
    } else {
        showNotification(String((res && res.message) || '和訳の保存に失敗しました'));
    }
}
