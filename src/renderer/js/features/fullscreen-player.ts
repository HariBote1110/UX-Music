// @ts-nocheck
// フルスクリーンプレイヤー — BroadcastChannel でメインウィンドウと状態を同期する

const CHANNEL_NAME = 'ux-music-fullscreen';

// ---- DOM 参照 ----
const artworkEl = document.getElementById('fs-artwork') as HTMLImageElement;
const titleEl = document.getElementById('fs-title');
const artistEl = document.getElementById('fs-artist');
const progressFill = document.getElementById('fs-progress-fill');
const progressThumb = document.getElementById('fs-progress-thumb');
const progressContainer = document.getElementById('fs-progress-container');
const currentTimeEl = document.getElementById('fs-current-time');
const durationEl = document.getElementById('fs-duration');
const playBtn = document.getElementById('fs-play-btn');
const prevBtn = document.getElementById('fs-prev-btn');
const nextBtn = document.getElementById('fs-next-btn');
const shuffleBtn = document.getElementById('fs-shuffle-btn');
const loopBtn = document.getElementById('fs-loop-btn');
const lyricsView = document.getElementById('lyrics-view');
const closeBtn = document.getElementById('close-btn');

// ---- 状態 ----
let currentDuration = 0;
let currentTime = 0;
let isSeeking = false;
let lyricsLineElements: HTMLElement[] = [];
let currentLyricsMode: string | null = null;
let currentLyrics: any[] | null = null;
let currentLyricsType: string | null = null;
let currentAnimatedIndex = -1;
let lastResolvedIndex = -1;
const ANCHOR_RATIO = 0.35;
const INTER_BLOCK_GAP = 16;
const MOTION_DURATION_MS = 800;
const MOTION_DELAY_STEP_MS = 40;

// ---- BroadcastChannel ----
const bc = new BroadcastChannel(CHANNEL_NAME);

bc.addEventListener('message', (event) => {
    const msg = event.data;
    if (!msg || !msg.type) return;

    switch (msg.type) {
        case 'state-update':
            applyStateUpdate(msg);
            break;
        case 'time-update':
            if (!isSeeking) {
                currentTime = msg.currentTime;
                currentDuration = msg.duration;
                updateProgress(msg.currentTime, msg.duration);
                syncLyricsToTime(msg.currentTime);
            }
            break;
        case 'play-state':
            setPlayState(msg.isPlaying);
            break;
        case 'colour-update':
            applyBackgroundColours(msg.colour1, msg.colour2);
            break;
    }
});

// メインウィンドウに準備完了を通知
bc.postMessage({ type: 'fullscreen-ready' });

// ---- 状態適用 ----
function applyStateUpdate(msg) {
    if (msg.song) {
        applyTrackInfo(msg.song);
    }
    if (msg.colour1 && msg.colour2) {
        applyBackgroundColours(msg.colour1, msg.colour2);
    }
    if (msg.lyrics !== undefined) {
        renderLyrics(msg.lyrics, msg.lyricsType);
    }
    if (typeof msg.isPlaying === 'boolean') {
        setPlayState(msg.isPlaying);
    }
    if (typeof msg.currentTime === 'number') {
        currentTime = msg.currentTime;
        currentDuration = msg.duration ?? 0;
        updateProgress(msg.currentTime, msg.duration ?? 0);
    }
}

function applyTrackInfo(song) {
    titleEl.textContent = song.title || '不明なタイトル';
    artistEl.textContent = song.artist || '';
    if (song.artworkSrc) {
        artworkEl.src = song.artworkSrc;
    }
}

function applyBackgroundColours(c1: string, c2: string) {
    document.documentElement.style.setProperty('--bg-colour-1', c1);
    document.documentElement.style.setProperty('--bg-colour-2', c2);
}

// ---- 進捗バー ----
function updateProgress(time: number, duration: number) {
    if (!duration || !isFinite(duration)) return;
    const pct = Math.min(1, Math.max(0, time / duration)) * 100;
    progressFill.style.width = `${pct}%`;
    progressThumb.style.left = `${pct}%`;
    currentTimeEl.textContent = formatTime(time);
    durationEl.textContent = formatTime(duration);
}

function formatTime(seconds: number): string {
    if (!isFinite(seconds) || seconds < 0) return '0:00';
    const m = Math.floor(seconds / 60);
    const s = Math.floor(seconds % 60);
    return `${m}:${s.toString().padStart(2, '0')}`;
}

// シーク操作
progressContainer.addEventListener('mousedown', (e: MouseEvent) => {
    isSeeking = true;
    doSeek(e);
});

window.addEventListener('mousemove', (e: MouseEvent) => {
    if (!isSeeking) return;
    doSeek(e);
});

window.addEventListener('mouseup', (e: MouseEvent) => {
    if (!isSeeking) return;
    isSeeking = false;
    doSeek(e);
    bc.postMessage({ type: 'control', action: 'seek', value: currentTime });
});

function doSeek(e: MouseEvent) {
    const rect = progressContainer.getBoundingClientRect();
    const ratio = Math.min(1, Math.max(0, (e.clientX - rect.left) / rect.width));
    currentTime = ratio * currentDuration;
    updateProgress(currentTime, currentDuration);
}

// ---- 再生状態 ----
function setPlayState(playing: boolean) {
    if (playing) {
        playBtn.classList.add('playing');
    } else {
        playBtn.classList.remove('playing');
    }
}

// ---- ボタン操作 ----
playBtn.addEventListener('click', () => {
    bc.postMessage({ type: 'control', action: 'toggle-play' });
});

prevBtn.addEventListener('click', () => {
    bc.postMessage({ type: 'control', action: 'prev' });
});

nextBtn.addEventListener('click', () => {
    bc.postMessage({ type: 'control', action: 'next' });
});

shuffleBtn.addEventListener('click', () => {
    bc.postMessage({ type: 'control', action: 'shuffle' });
});

loopBtn.addEventListener('click', () => {
    bc.postMessage({ type: 'control', action: 'loop' });
});

closeBtn.addEventListener('click', () => {
    window.close();
});

// ---- 歌詞描画 ----
function renderLyrics(lyrics: any, lyricsType: string | null) {
    lyricsView.innerHTML = '';
    lyricsView.className = '';
    lyricsLineElements = [];
    currentLyrics = null;
    currentLyricsType = lyricsType;
    currentAnimatedIndex = -1;
    lastResolvedIndex = -1;

    if (!lyrics) {
        lyricsView.innerHTML = '<p class="no-lyrics">歌詞はありません</p>';
        return;
    }

    if (lyricsType === 'lrc' && Array.isArray(lyrics) && lyrics.length > 0 && typeof lyrics[0].time === 'number') {
        currentLyrics = lyrics;
        lyricsView.classList.add('lyrics-mode-lrc');
        const bilingual = lyrics.some(l => l.translation);
        if (bilingual) lyricsView.classList.add('lyrics-mode-bilingual');

        lyrics.forEach((line, i) => {
            const p = document.createElement('p');
            p.dataset.index = String(i);
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
            lyricsView.appendChild(p);
        });

        lyricsLineElements = Array.from(lyricsView.querySelectorAll('p[data-index]')) as HTMLElement[];
        applyLyricsMotion(-1, true);
    } else if (typeof lyrics === 'string') {
        lyricsView.classList.add('lyrics-mode-txt');
        lyrics.split('\n').forEach((line, i) => {
            const p = document.createElement('p');
            p.textContent = line.trim() === '' ? '\u00A0' : line;
            if (i > 0) p.classList.add('line-break');
            lyricsView.appendChild(p);
        });
    } else if (Array.isArray(lyrics)) {
        lyricsView.classList.add('lyrics-mode-txt');
        const bilingual = lyrics.some(l => l && l.translation);
        if (bilingual) lyricsView.classList.add('lyrics-mode-bilingual');
        lyrics.forEach((line, i) => {
            const p = document.createElement('p');
            if (i > 0) p.classList.add('line-break');
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
                p.textContent = typeof line === 'string' ? line : (line.text ?? '');
            }
            lyricsView.appendChild(p);
        });
    }
}

// ---- LRC アニメーション ----
function applyLyricsMotion(activeIndex: number, immediate = false) {
    const lines = lyricsLineElements;
    if (lines.length === 0) return;

    const container = lyricsView;
    const baseIndex = activeIndex >= 0 ? activeIndex : 0;
    const anchorY = container.clientHeight * ANCHOR_RATIO;
    const motionDuration = immediate ? 0 : MOTION_DURATION_MS;

    lines.forEach((line, i) => {
        line.classList.toggle('active', i === activeIndex);
    });

    const heights = lines.map(el => {
        const h = el.getBoundingClientRect().height;
        return Number.isFinite(h) && h > 0 ? h : 1;
    });

    const n = heights.length;
    const tops = new Array(n);
    const b = Math.min(Math.max(0, baseIndex), n - 1);
    tops[b] = anchorY;
    for (let i = b + 1; i < n; i++) tops[i] = tops[i - 1] + heights[i - 1] + INTER_BLOCK_GAP;
    for (let i = b - 1; i >= 0; i--) tops[i] = tops[i + 1] - heights[i] - INTER_BLOCK_GAP;

    const refForDelay = activeIndex >= 0 ? activeIndex : 0;
    lines.forEach((line, i) => {
        const dist = Math.abs(i - refForDelay);
        line.style.setProperty('--line-motion-delay', immediate ? '0ms' : `${dist * MOTION_DELAY_STEP_MS}ms`);
        line.style.setProperty('--line-motion-duration', `${motionDuration}ms`);
        line.style.setProperty('--lyrics-line-y', `${tops[i].toFixed(2)}px`);
    });

    currentAnimatedIndex = activeIndex;
}

function findLyricsIndexForTime(time: number): number {
    const lyrics = currentLyrics;
    if (!Array.isArray(lyrics) || lyrics.length === 0) { lastResolvedIndex = -1; return -1; }
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

function syncLyricsToTime(time: number) {
    if (!currentLyrics || currentLyricsType !== 'lrc') return;
    const idx = findLyricsIndexForTime(time);
    if (idx !== currentAnimatedIndex) {
        applyLyricsMotion(idx, false);
    }
}

// リサイズ時に再レイアウト
window.addEventListener('resize', () => {
    if (!lyricsView.classList.contains('lyrics-mode-lrc')) return;
    requestAnimationFrame(() => applyLyricsMotion(currentAnimatedIndex, true));
});
