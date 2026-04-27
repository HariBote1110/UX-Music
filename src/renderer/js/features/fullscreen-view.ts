// フルスクリーンオーバーレイ — 既存ウィンドウ内に全画面表示する

import { state, elements, PLAYBACK_MODES } from '../core/state.js';
import { getCurrentTime, getDuration, isPlaying, togglePlayPause, seek } from './player.js';
import { playNextSong, playPrevSong, playSong } from './playback-manager.js';
import { DEFAULT_ARTWORK_URL } from '../constants/default-artwork.js';
import { animateIconPaths } from '../ui/player-ui.js';

// ---- 内部状態 ----
let overlayEl: HTMLElement | null = null;
let lyricsEl: HTMLElement | null = null;
let progressFill: HTMLElement | null = null;
let progressThumb: HTMLElement | null = null;
let currentTimeEl: HTMLElement | null = null;
let durationEl: HTMLElement | null = null;
let playBtn: HTMLElement | null = null;
let artworkEl: HTMLImageElement | null = null;
let titleEl: HTMLElement | null = null;
let artistEl: HTMLElement | null = null;

let shuffleBtn: HTMLElement | null = null;
let loopBtn: HTMLElement | null = null;
let fsPlayPart1: SVGPathElement | null = null;
let queueEl: HTMLElement | null = null;
let lyricsContainer: HTMLElement | null = null;
let queueContainer: HTMLElement | null = null;
let activeTab: 'lyrics' | 'queue' = 'lyrics';
let fsPlayPart2: SVGPathElement | null = null;
let fsShuffleAnimRunning = false;
let fsLoopAnimRunning = false;
let lastSyncedPlayState: boolean | null = null;
let tickerId: ReturnType<typeof setInterval> | null = null;
let isSeeking = false;
let seekRatio = 0;

let lyricsLineElements: HTMLElement[] = [];
let currentLyricsType: string | null = null;
let currentAnimatedIndex = -1;
let lastResolvedIndex = -1;

const ANCHOR_RATIO = 0.35;
const INTER_BLOCK_GAP = 16;
const MOTION_DURATION_MS = 800;
const MOTION_DELAY_STEP_MS = 40;

// ---- 公開 API ----

export function openFullscreenView() {
    if (!overlayEl) {
        overlayEl = buildOverlay();
        document.body.appendChild(overlayEl);
    }
    lastSyncedPlayState = null;
    syncAll();
    overlayEl.classList.add('fs-open');
    startTicker();
    document.addEventListener('keydown', handleKeydown);
}

export function closeFullscreenView() {
    overlayEl?.classList.remove('fs-open');
    stopTicker();
    document.removeEventListener('keydown', handleKeydown);
}

/** 曲が変わったときに呼ぶ */
export function notifyFullscreenSongChange() {
    if (!isOpen()) return;
    syncSongInfo();
    syncLyrics();
    syncColours();
    if (activeTab === 'queue') renderQueue();
}

/** 歌詞が変わったときに呼ぶ */
export function notifyFullscreenLyricsChange() {
    if (!isOpen()) return;
    syncLyrics();
}

// ---- 内部ユーティリティ ----

function isOpen() {
    return overlayEl?.classList.contains('fs-open') ?? false;
}

function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') closeFullscreenView();
}

function startTicker() {
    stopTicker();
    tickerId = setInterval(() => {
        if (!isOpen()) return;
        const time = getCurrentTime();
        const dur = getDuration();
        if (!isSeeking) updateProgress(time, dur);
        syncPlayState(isPlaying());
        syncButtonStates();
        syncLyricsToTime(time);
    }, 200);
}

function stopTicker() {
    if (tickerId != null) {
        clearInterval(tickerId);
        tickerId = null;
    }
}

// ---- 状態同期 ----

function syncAll() {
    syncSongInfo();
    syncLyrics();
    syncColours();
    syncPlayState(isPlaying());
    syncButtonStates();
    const time = getCurrentTime();
    const dur = getDuration();
    updateProgress(time, dur);
}

function syncButtonStates() {
    if (shuffleBtn) {
        shuffleBtn.classList.toggle('active', state.isShuffled);
    }
    if (loopBtn) {
        const isActive = state.playbackMode !== PLAYBACK_MODES.NORMAL;
        const isLoopOne = state.playbackMode === PLAYBACK_MODES.LOOP_ONE;
        loopBtn.classList.toggle('active', isActive);
        loopBtn.classList.toggle('loop-one', isLoopOne);
    }
}

function switchTab(tab: 'lyrics' | 'queue', root: HTMLElement) {
    activeTab = tab;
    root.querySelectorAll('.fs-tab-label').forEach((t) => {
        (t as HTMLElement).classList.toggle('active', (t as HTMLElement).dataset.tab === tab);
    });
    lyricsContainer?.classList.toggle('hidden', tab !== 'lyrics');
    queueContainer?.classList.toggle('hidden', tab !== 'queue');
    if (tab === 'queue') renderQueue();
}

function renderQueue() {
    if (!queueEl) return;
    const queue = state.playbackQueue;
    const current = state.currentSongIndex;
    queueEl.innerHTML = '';

    queue.forEach((song, i) => {
        const item = document.createElement('div');
        item.className = 'fs-queue-item' + (i === current ? ' active' : '');

        const info = document.createElement('div');
        info.className = 'fs-queue-info';

        const title = document.createElement('div');
        title.className = 'fs-queue-title';
        title.textContent = song.title || '不明なタイトル';

        const artist = document.createElement('div');
        artist.className = 'fs-queue-artist';
        artist.textContent = song.artist || '';

        info.appendChild(title);
        info.appendChild(artist);
        item.appendChild(info);

        item.addEventListener('click', () => playSong(i, null, true));
        queueEl!.appendChild(item);
    });

    // 現在の曲を中央付近にスクロール
    const activeItem = queueEl.querySelector('.fs-queue-item.active') as HTMLElement | null;
    if (activeItem) {
        activeItem.scrollIntoView({ block: 'center', behavior: 'instant' });
    }
}

function syncSongInfo() {
    const song = state.playbackQueue?.[state.currentSongIndex];
    if (!song) return;

    if (titleEl) titleEl.textContent = song.title || '不明なタイトル';
    if (artistEl) artistEl.textContent = song.artist || '';

    // アートワークはサイドバーの img から取得
    const sidebarImg = elements.nowPlayingArtworkContainer?.querySelector('img');
    if (artworkEl) {
        artworkEl.src = sidebarImg?.src || DEFAULT_ARTWORK_URL;
    }
}

function syncColours() {
    const style = getComputedStyle(document.documentElement);
    const c1 = style.getPropertyValue('--eq-color-1').trim() || 'var(--highlight-pink)';
    const c2 = style.getPropertyValue('--eq-color-2').trim() || 'var(--highlight-blue)';
    if (overlayEl) {
        overlayEl.style.setProperty('--fs-bg-1', c1);
        overlayEl.style.setProperty('--fs-bg-2', c2);
    }
}

function syncPlayState(playing: boolean) {
    if (!playBtn) return;
    playBtn.classList.toggle('playing', playing);
    if (playing !== lastSyncedPlayState) {
        lastSyncedPlayState = playing;
        animateIconPaths(fsPlayPart1, fsPlayPart2, playing);
    }
}

// ---- 進捗バー ----

function updateProgress(time: number, dur: number) {
    if (!dur || !isFinite(dur)) return;
    const pct = Math.min(1, Math.max(0, time / dur)) * 100;
    if (progressFill) progressFill.style.width = `${pct}%`;
    if (progressThumb) progressThumb.style.left = `${pct}%`;
    if (currentTimeEl) currentTimeEl.textContent = formatTime(time);
    if (durationEl) durationEl.textContent = formatTime(dur);
}

function formatTime(s: number): string {
    if (!isFinite(s) || s < 0) return '0:00';
    const m = Math.floor(s / 60);
    return `${m}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
}

// ---- 歌詞同期 ----

function syncLyrics() {
    if (!lyricsEl) return;
    lyricsEl.innerHTML = '';
    lyricsEl.className = 'fs-lyrics-inner';
    lyricsLineElements = [];
    currentLyricsType = state.currentLyricsType;
    currentAnimatedIndex = -1;
    lastResolvedIndex = -1;

    const lyrics = state.currentLyrics;

    if (!lyrics && state.currentLyricsType == null) {
        lyricsEl.innerHTML = '<p class="fs-no-lyrics">歌詞はありません</p>';
        return;
    }

    if (state.currentLyricsType === 'lrc' && Array.isArray(lyrics) && lyrics.length > 0) {
        lyricsEl.classList.add('fs-lrc');
        const bilingual = lyrics.some(l => l.translation);
        if (bilingual) lyricsEl.classList.add('fs-bilingual');

        lyrics.forEach((line, i) => {
            const p = document.createElement('p');
            p.dataset.index = String(i);
            if (bilingual && line.translation) {
                p.classList.add('fs-line-bilingual');
                const pri = document.createElement('span');
                pri.className = 'fs-line-primary';
                pri.textContent = line.text;
                p.appendChild(pri);
                const tr = document.createElement('span');
                tr.className = 'fs-line-translation';
                tr.textContent = line.translation;
                p.appendChild(tr);
            } else {
                p.textContent = line.text;
            }
            lyricsEl.appendChild(p);
        });
        lyricsLineElements = Array.from(lyricsEl.querySelectorAll('p[data-index]'));
        applyLyricsMotion(-1, true);
    } else {
        // TXT or plain array
        lyricsEl.classList.add('fs-txt');
        const lines: any[] = Array.isArray(lyrics)
            ? lyrics
            : (typeof lyrics === 'string' ? lyrics.split('\n').map(t => ({ text: t })) : []);
        const bilingual = lines.some(l => l && l.translation);
        if (bilingual) lyricsEl.classList.add('fs-bilingual');
        lines.forEach((line, i) => {
            const p = document.createElement('p');
            if (i > 0) p.classList.add('fs-line-break');
            if (bilingual && line.translation) {
                p.classList.add('fs-line-bilingual');
                const pri = document.createElement('span');
                pri.className = 'fs-line-primary';
                pri.textContent = line.text;
                p.appendChild(pri);
                const tr = document.createElement('span');
                tr.className = 'fs-line-translation';
                tr.textContent = line.translation;
                p.appendChild(tr);
            } else {
                p.textContent = typeof line === 'string' ? line : (line.text ?? '');
            }
            lyricsEl.appendChild(p);
        });
    }
}

function syncLyricsToTime(time: number) {
    if (currentLyricsType !== 'lrc') return;
    const lyrics = state.currentLyrics;
    if (!Array.isArray(lyrics) || lyrics.length === 0) return;

    const idx = findLyricsIndex(lyrics, time);
    if (idx !== currentAnimatedIndex) {
        applyLyricsMotion(idx, false);
    }
}

function findLyricsIndex(lyrics: any[], time: number): number {
    if (time < lyrics[0].time) { lastResolvedIndex = -1; return -1; }
    const last = lyrics.length - 1;
    if (time >= lyrics[last].time) { lastResolvedIndex = last; return last; }

    if (lastResolvedIndex >= 0 && lastResolvedIndex < lyrics.length) {
        const cur = lyrics[lastResolvedIndex];
        const next = lyrics[lastResolvedIndex + 1];
        if (time >= cur.time && (!next || time < next.time)) return lastResolvedIndex;
        if (next && time >= next.time) {
            let idx = lastResolvedIndex + 1;
            while (idx < last && time >= lyrics[idx + 1].time) idx++;
            lastResolvedIndex = idx;
            return idx;
        }
    }

    let lo = 0, hi = last, resolved = -1;
    while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        if (lyrics[mid].time <= time) { resolved = mid; lo = mid + 1; } else { hi = mid - 1; }
    }
    lastResolvedIndex = resolved;
    return resolved;
}

function applyLyricsMotion(activeIndex: number, immediate = false) {
    const lines = lyricsLineElements;
    if (lines.length === 0) return;
    if (!lyricsEl) return;

    const baseIndex = activeIndex >= 0 ? activeIndex : 0;
    const anchorY = lyricsEl.clientHeight * ANCHOR_RATIO;
    const dur = immediate ? 0 : MOTION_DURATION_MS;

    lines.forEach((line, i) => line.classList.toggle('active', i === activeIndex));

    const heights = lines.map(el => {
        const h = el.getBoundingClientRect().height;
        return h > 0 ? h : 1;
    });

    const n = heights.length;
    const tops = new Array(n);
    const b = Math.min(Math.max(0, baseIndex), n - 1);
    tops[b] = anchorY;
    for (let i = b + 1; i < n; i++) tops[i] = tops[i - 1] + heights[i - 1] + INTER_BLOCK_GAP;
    for (let i = b - 1; i >= 0; i--) tops[i] = tops[i + 1] - heights[i] - INTER_BLOCK_GAP;

    lines.forEach((line, i) => {
        const dist = Math.abs(i - (activeIndex >= 0 ? activeIndex : 0));
        line.style.setProperty('--fs-line-delay', immediate ? '0ms' : `${dist * MOTION_DELAY_STEP_MS}ms`);
        line.style.setProperty('--fs-line-dur', `${dur}ms`);
        line.style.setProperty('--fs-line-y', `${tops[i].toFixed(2)}px`);
    });

    currentAnimatedIndex = activeIndex;
}

// ---- シャッフル・ループ ボタン アニメーション ----

const FS_POS_STANDARD = 100;
const FS_POS_EXIT     = 130;
const FS_POS_ENTER    = -30;
const fsDashOf = (pos: number, len: number) => len - (pos / 100) * len;

function initialiseFsShuffleLoop() {
    const initPaths = (btn: HTMLElement | null, topClass: string, botClass: string) => {
        if (!btn) return;
        const pathTop = btn.querySelector(topClass) as SVGGeometryElement | null;
        const pathBot = btn.querySelector(botClass) as SVGGeometryElement | null;
        if (!pathTop || !pathBot) return;
        const tLen = pathTop.getTotalLength();
        const bLen = pathBot.getTotalLength();
        (pathTop as SVGPathElement & { dataset: DOMStringMap }).dataset.totalLength = String(tLen);
        (pathBot as SVGPathElement & { dataset: DOMStringMap }).dataset.totalLength = String(bLen);
        pathTop.style.strokeDasharray  = `${tLen} ${tLen * 3}`;
        pathTop.style.strokeDashoffset = '0';
        pathBot.style.strokeDasharray  = `${bLen} ${bLen * 3}`;
        pathBot.style.strokeDashoffset = '0';
    };
    initPaths(shuffleBtn, '.shuffle-path-top', '.shuffle-path-bottom');
    initPaths(loopBtn,    '.loop-path-top',    '.loop-path-bottom');
}

async function runFsShuffleAnimation() {
    if (fsShuffleAnimRunning || !shuffleBtn) return;
    fsShuffleAnimRunning = true;

    const pathTop    = shuffleBtn.querySelector('.shuffle-path-top') as SVGGeometryElement | null;
    const pathBottom = shuffleBtn.querySelector('.shuffle-path-bottom') as SVGGeometryElement | null;
    const headTop    = shuffleBtn.querySelector('.shuffle-head-top') as SVGElement | null;
    const headBottom = shuffleBtn.querySelector('.shuffle-head-bottom') as SVGElement | null;
    if (!pathTop || !pathBottom) { fsShuffleAnimRunning = false; return; }

    const topLen    = parseFloat((pathTop as SVGPathElement & { dataset: DOMStringMap }).dataset.totalLength)    || pathTop.getTotalLength();
    const bottomLen = parseFloat((pathBottom as SVGPathElement & { dataset: DOMStringMap }).dataset.totalLength) || pathBottom.getTotalLength();
    const svgEl = shuffleBtn.querySelector('svg');
    const scale = svgEl ? svgEl.getBoundingClientRect().width / 24 : 22 / 24;
    const headExitX  = (FS_POS_EXIT  - FS_POS_STANDARD) / 100 * topLen * scale;
    const headEnterX = (FS_POS_ENTER - FS_POS_STANDARD) / 100 * topLen * scale;

    const timingExit  = { duration: 200, easing: 'ease-in',                       fill: 'forwards' as FillMode };
    const timingEnter = { duration: 400, easing: 'cubic-bezier(0.16, 1, 0.3, 1)', fill: 'forwards' as FillMode };

    const exitAnims: Animation[] = [
        pathTop.animate([{ strokeDashoffset: fsDashOf(FS_POS_STANDARD, topLen) },    { strokeDashoffset: fsDashOf(FS_POS_EXIT, topLen) }],    timingExit),
        pathBottom.animate([{ strokeDashoffset: fsDashOf(FS_POS_STANDARD, bottomLen) }, { strokeDashoffset: fsDashOf(FS_POS_EXIT, bottomLen) }], timingExit),
    ];
    if (headTop)    exitAnims.push(headTop.animate([{ transform: 'translateX(0px)' }, { transform: `translateX(${headExitX}px)` }], timingExit));
    if (headBottom) exitAnims.push(headBottom.animate([{ transform: 'translateX(0px)' }, { transform: `translateX(${headExitX}px)` }], timingExit));
    await Promise.all(exitAnims.map(a => a.finished));

    const enterAnims: Animation[] = [
        pathTop.animate([{ strokeDashoffset: fsDashOf(FS_POS_ENTER, topLen) },    { strokeDashoffset: fsDashOf(FS_POS_STANDARD, topLen) }],    timingEnter),
        pathBottom.animate([{ strokeDashoffset: fsDashOf(FS_POS_ENTER, bottomLen) }, { strokeDashoffset: fsDashOf(FS_POS_STANDARD, bottomLen) }], timingEnter),
    ];
    if (headTop)    enterAnims.push(headTop.animate([{ transform: `translateX(${headEnterX}px)` }, { transform: 'translateX(0px)' }], timingEnter));
    if (headBottom) enterAnims.push(headBottom.animate([{ transform: `translateX(${headEnterX}px)` }, { transform: 'translateX(0px)' }], timingEnter));
    await Promise.all(enterAnims.map(a => a.finished));

    pathTop.style.strokeDashoffset    = '0';
    pathBottom.style.strokeDashoffset = '0';
    if (headTop)    (headTop as unknown as HTMLElement).style.transform    = '';
    if (headBottom) (headBottom as unknown as HTMLElement).style.transform = '';
    [...exitAnims, ...enterAnims].forEach(a => a.cancel());
    fsShuffleAnimRunning = false;
}

async function runFsLoopAnimation() {
    if (fsLoopAnimRunning || !loopBtn) return;
    fsLoopAnimRunning = true;

    const pathTop    = loopBtn.querySelector('.loop-path-top') as SVGGeometryElement | null;
    const pathBottom = loopBtn.querySelector('.loop-path-bottom') as SVGGeometryElement | null;
    const headTop    = loopBtn.querySelector('.loop-head-top') as SVGElement | null;
    const headBottom = loopBtn.querySelector('.loop-head-bottom') as SVGElement | null;
    if (!pathTop || !pathBottom) { fsLoopAnimRunning = false; return; }

    const topLen    = parseFloat((pathTop as SVGPathElement & { dataset: DOMStringMap }).dataset.totalLength)    || pathTop.getTotalLength();
    const bottomLen = parseFloat((pathBottom as SVGPathElement & { dataset: DOMStringMap }).dataset.totalLength) || pathBottom.getTotalLength();
    const svgEl = loopBtn.querySelector('svg');
    const scale = svgEl ? svgEl.getBoundingClientRect().width / 24 : 22 / 24;
    const topExitX  =  (FS_POS_EXIT  - FS_POS_STANDARD) / 100 * topLen    * scale;
    const topEnterX =  (FS_POS_ENTER - FS_POS_STANDARD) / 100 * topLen    * scale;
    const botExitX  = -(FS_POS_EXIT  - FS_POS_STANDARD) / 100 * bottomLen * scale;
    const botEnterX = -(FS_POS_ENTER - FS_POS_STANDARD) / 100 * bottomLen * scale;

    const timingExit  = { duration: 200, easing: 'ease-in',                       fill: 'forwards' as FillMode };
    const timingEnter = { duration: 400, easing: 'cubic-bezier(0.16, 1, 0.3, 1)', fill: 'forwards' as FillMode };

    const exitAnims: Animation[] = [
        pathTop.animate([{ strokeDashoffset: fsDashOf(FS_POS_STANDARD, topLen) },    { strokeDashoffset: fsDashOf(FS_POS_EXIT, topLen) }],    timingExit),
        pathBottom.animate([{ strokeDashoffset: fsDashOf(FS_POS_STANDARD, bottomLen) }, { strokeDashoffset: fsDashOf(FS_POS_EXIT, bottomLen) }], timingExit),
    ];
    if (headTop)    exitAnims.push(headTop.animate([{ transform: 'translateX(0px)' }, { transform: `translateX(${topExitX}px)` }], timingExit));
    if (headBottom) exitAnims.push(headBottom.animate([{ transform: 'translateX(0px)' }, { transform: `translateX(${botExitX}px)` }], timingExit));
    await Promise.all(exitAnims.map(a => a.finished));

    const enterAnims: Animation[] = [
        pathTop.animate([{ strokeDashoffset: fsDashOf(FS_POS_ENTER, topLen) },    { strokeDashoffset: fsDashOf(FS_POS_STANDARD, topLen) }],    timingEnter),
        pathBottom.animate([{ strokeDashoffset: fsDashOf(FS_POS_ENTER, bottomLen) }, { strokeDashoffset: fsDashOf(FS_POS_STANDARD, bottomLen) }], timingEnter),
    ];
    if (headTop)    enterAnims.push(headTop.animate([{ transform: `translateX(${topEnterX}px)` }, { transform: 'translateX(0px)' }], timingEnter));
    if (headBottom) enterAnims.push(headBottom.animate([{ transform: `translateX(${botEnterX}px)` }, { transform: 'translateX(0px)' }], timingEnter));
    await Promise.all(enterAnims.map(a => a.finished));

    pathTop.style.strokeDashoffset    = '0';
    pathBottom.style.strokeDashoffset = '0';
    if (headTop)    (headTop as unknown as HTMLElement).style.transform    = '';
    if (headBottom) (headBottom as unknown as HTMLElement).style.transform = '';
    [...exitAnims, ...enterAnims].forEach(a => a.cancel());
    fsLoopAnimRunning = false;
}

// ---- オーバーレイDOM構築 ----

function buildOverlay(): HTMLElement {
    const el = document.createElement('div');
    el.id = 'fs-overlay';
    el.className = 'fs-overlay';

    el.innerHTML = `
        <button class="fs-close-btn" id="fs-close-btn" aria-label="閉じる">
            <svg viewBox="0 0 24 24"><path d="M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"/></svg>
        </button>

        <div class="fs-left">
            <div class="fs-artwork-wrapper">
                <img id="fs-artwork" src="${DEFAULT_ARTWORK_URL}" alt="Album Artwork">
            </div>
            <div class="fs-track-info">
                <div class="fs-title" id="fs-title">曲を選択してください</div>
                <div class="fs-artist" id="fs-artist"></div>
            </div>
            <div class="fs-progress-area">
                <div class="fs-progress-bar" id="fs-progress-bar">
                    <div class="fs-progress-fill" id="fs-progress-fill"></div>
                    <div class="fs-progress-thumb" id="fs-progress-thumb"></div>
                </div>
                <div class="fs-time-row">
                    <span id="fs-current-time">0:00</span>
                    <span id="fs-duration">0:00</span>
                </div>
            </div>
            <div class="fs-controls">
                <button class="fs-btn" id="fs-shuffle-btn" aria-label="シャッフル">
                    <svg class="shuffle-icon fs-svg-btn" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                        <path class="shuffle-path-top" d="M 2 18 L 7 18 C 10 18 14 6 17 6 L 22 6" />
                        <path class="shuffle-head-top" d="M 19 3 L 22 6 L 19 9" />
                        <path class="shuffle-path-bottom" d="M 2 6 L 7 6 C 10 6 14 18 17 18 L 22 18" />
                        <path class="shuffle-head-bottom" d="M 19 15 L 22 18 L 19 21" />
                    </svg>
                </button>
                <button class="fs-btn" id="fs-prev-btn" aria-label="前の曲">
                    <img src="./assets/icons/rewind_skip.svg" alt="前の曲">
                </button>
                <button class="fs-btn fs-play-btn" id="fs-play-btn" aria-label="再生・一時停止">
                    <svg class="play-pause-icon" viewBox="0 0 24 24">
                        <path class="icon-part-1" d="M 8 5 L 18 12 L 8 12 L 8 5 Z"></path>
                        <path class="icon-part-2" d="M 8 19 L 18 12 L 8 12 L 8 19 Z"></path>
                    </svg>
                </button>
                <button class="fs-btn" id="fs-next-btn" aria-label="次の曲">
                    <img src="./assets/icons/next_skip.svg" alt="次の曲">
                </button>
                <button class="fs-btn" id="fs-loop-btn" aria-label="リピート">
                    <svg class="loop-icon fs-svg-btn" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                        <path class="loop-path-top" d="M3 12 a5 5 0 0 1 5-5 H21" />
                        <path class="loop-head-top" d="M18 4 L21 7 L18 10" />
                        <path class="loop-path-bottom" d="M21 12 a5 5 0 0 1-5 5 H3" />
                        <path class="loop-head-bottom" d="M6 14 L3 17 L6 20" />
                    </svg>
                </button>
            </div>
        </div>

        <div class="fs-right">
            <div class="fs-tab-nav">
                <button class="fs-tab-label active" data-tab="lyrics">歌詞</button>
                <button class="fs-tab-label" data-tab="queue">キュー</button>
            </div>
            <div class="fs-lyrics-container" id="fs-lyrics-container">
                <div class="fs-lyrics-inner" id="fs-lyrics"></div>
            </div>
            <div class="fs-queue-container hidden" id="fs-queue-container">
                <div class="fs-queue-inner" id="fs-queue"></div>
            </div>
        </div>
    `;

    // DOM参照
    artworkEl     = el.querySelector('#fs-artwork');
    titleEl       = el.querySelector('#fs-title');
    artistEl      = el.querySelector('#fs-artist');
    progressFill  = el.querySelector('#fs-progress-fill');
    progressThumb = el.querySelector('#fs-progress-thumb');
    currentTimeEl = el.querySelector('#fs-current-time');
    durationEl    = el.querySelector('#fs-duration');
    playBtn       = el.querySelector('#fs-play-btn');
    shuffleBtn    = el.querySelector('#fs-shuffle-btn');
    loopBtn       = el.querySelector('#fs-loop-btn');
    lyricsEl       = el.querySelector('#fs-lyrics');
    queueEl        = el.querySelector('#fs-queue');
    lyricsContainer = el.querySelector('#fs-lyrics-container');
    queueContainer  = el.querySelector('#fs-queue-container');
    fsPlayPart1    = el.querySelector('#fs-play-btn .icon-part-1');
    fsPlayPart2    = el.querySelector('#fs-play-btn .icon-part-2');

    initialiseFsShuffleLoop();

    // タブ切り替え
    el.querySelectorAll('.fs-tab-label').forEach((tab) => {
        tab.addEventListener('click', () => {
            const t = (tab as HTMLElement).dataset.tab as 'lyrics' | 'queue';
            switchTab(t, el);
        });
    });

    // 閉じるボタン
    el.querySelector('#fs-close-btn').addEventListener('click', () => closeFullscreenView());

    // 再生コントロール
    el.querySelector('#fs-play-btn').addEventListener('click', () => togglePlayPause());
    el.querySelector('#fs-prev-btn').addEventListener('click', () => playPrevSong());
    el.querySelector('#fs-next-btn').addEventListener('click', () => playNextSong());

    // シャッフル・ループは既存ボタンにフォワード＋アニメーション実行
    el.querySelector('#fs-shuffle-btn').addEventListener('click', () => {
        document.getElementById('shuffle-btn')?.click();
        void runFsShuffleAnimation();
    });
    el.querySelector('#fs-loop-btn').addEventListener('click', () => {
        document.getElementById('loop-btn')?.click();
        void runFsLoopAnimation();
    });

    // シークバー
    const bar = el.querySelector('#fs-progress-bar') as HTMLElement;
    bar.addEventListener('mousedown', (e: MouseEvent) => {
        isSeeking = true;
        doSeek(e, bar);
    });
    window.addEventListener('mousemove', (e: MouseEvent) => {
        if (!isSeeking) return;
        doSeek(e, bar);
    });
    window.addEventListener('mouseup', (e: MouseEvent) => {
        if (!isSeeking) return;
        isSeeking = false;
        doSeek(e, bar);
        seek(seekRatio * getDuration());
    });

    // リサイズ時に歌詞再レイアウト
    window.addEventListener('resize', () => {
        if (!isOpen() || currentLyricsType !== 'lrc') return;
        requestAnimationFrame(() => applyLyricsMotion(currentAnimatedIndex, true));
    });

    return el;
}

function doSeek(e: MouseEvent, bar: HTMLElement) {
    const rect = bar.getBoundingClientRect();
    seekRatio = Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width));
    const dur = getDuration();
    if (dur) updateProgress(seekRatio * dur, dur);
}
