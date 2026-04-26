// @ts-nocheck
// フルスクリーンオーバーレイ — 既存ウィンドウ内に全画面表示する

import { state, elements } from '../core/state.js';
import { getCurrentTime, getDuration, isPlaying, togglePlayPause, seek } from './player.js';
import { playNextSong, playPrevSong } from './playback-manager.js';
import { DEFAULT_ARTWORK_URL } from '../constants/default-artwork.js';

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
        syncLyricsToTime(time);
        syncColours();
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
    const time = getCurrentTime();
    const dur = getDuration();
    updateProgress(time, dur);
}

function syncSongInfo() {
    const song = state.currentSong ?? state.playbackQueue?.[state.currentSongIndex];
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
                    <img src="./assets/icons/random.svg" alt="シャッフル">
                </button>
                <button class="fs-btn" id="fs-prev-btn" aria-label="前の曲">
                    <img src="./assets/icons/rewind_skip.svg" alt="前の曲">
                </button>
                <button class="fs-btn fs-play-btn" id="fs-play-btn" aria-label="再生・一時停止">
                    <img class="fs-icon-play" src="./assets/icons/play.svg" alt="再生">
                    <img class="fs-icon-pause" src="./assets/icons/pause.svg" alt="一時停止">
                </button>
                <button class="fs-btn" id="fs-next-btn" aria-label="次の曲">
                    <img src="./assets/icons/next_skip.svg" alt="次の曲">
                </button>
                <button class="fs-btn" id="fs-loop-btn" aria-label="リピート">
                    <img src="./assets/icons/repeat.svg" alt="リピート">
                </button>
            </div>
        </div>

        <div class="fs-right">
            <div class="fs-tab-nav">
                <span class="fs-tab-label">歌詞</span>
            </div>
            <div class="fs-lyrics-container">
                <div class="fs-lyrics-inner" id="fs-lyrics"></div>
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
    lyricsEl      = el.querySelector('#fs-lyrics');

    // 閉じるボタン
    el.querySelector('#fs-close-btn').addEventListener('click', () => closeFullscreenView());

    // 再生コントロール
    el.querySelector('#fs-play-btn').addEventListener('click', () => togglePlayPause());
    el.querySelector('#fs-prev-btn').addEventListener('click', () => playPrevSong());
    el.querySelector('#fs-next-btn').addEventListener('click', () => playNextSong());

    // シャッフル・ループは既存ボタンにフォワード
    el.querySelector('#fs-shuffle-btn').addEventListener('click', () => {
        document.getElementById('shuffle-btn')?.click();
    });
    el.querySelector('#fs-loop-btn').addEventListener('click', () => {
        document.getElementById('loop-btn')?.click();
    });

    // シークバー
    const bar = el.querySelector('#fs-progress-bar');
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
