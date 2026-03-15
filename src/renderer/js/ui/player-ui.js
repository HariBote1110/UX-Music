// src/renderer/js/player-ui.js

import { elements, state } from '../core/state.js';
import { updateLrcEditorControls } from '../features/lrc-editor.js';
import {
    seek,
    togglePlayPause,
    isPlaying,
    getCurrentTime,
    getDuration,
    playCurrent,
    pauseCurrent
} from '../features/player.js';
import { applyMasterVolume } from '../features/audio-graph.js';
import { formatTime } from './utils.js';
const electronAPI = window.electronAPI;

let isSeeking = false;
let wasPlayingBeforeSeek = false;
let progressUpdateInterval = null;
let progressFrameId = null;
let lastVolume = 0.5;
let iconAnimationId = null;
let volumeSaveTimer = null;
let shuffleAnimationRunning = false;

function getCurrentQueueSong() {
    if (!Array.isArray(state.playbackQueue) || state.currentSongIndex < 0) {
        return null;
    }
    return state.playbackQueue[state.currentSongIndex] || null;
}

function parsePositiveNumber(value) {
    if (typeof value === 'number' && Number.isFinite(value)) {
        return value > 0 ? value : null;
    }
    if (typeof value === 'string') {
        const parsed = Number(value.trim());
        if (Number.isFinite(parsed) && parsed > 0) {
            return parsed;
        }
    }
    return null;
}

function formatSampleRate(song) {
    const sampleRate = parsePositiveNumber(song?.sampleRate ?? song?.sample_rate);
    if (!sampleRate) return '-';

    const kiloHertz = sampleRate / 1000;
    const fixed = Number.isInteger(kiloHertz) ? kiloHertz.toString() : kiloHertz.toFixed(1).replace(/\.0$/, '');
    return `${fixed} kHz`;
}

function parseBitDepthFromSampleFormat(value) {
    if (typeof value !== 'string') return null;
    const sampleFormat = value.trim().toLowerCase();
    if (!sampleFormat) return null;

    const knownBitDepth = {
        u8: 8,
        u8p: 8,
        s8: 8,
        s8p: 8,
        s16: 16,
        s16p: 16,
        s24: 24,
        s24p: 24,
        s32: 32,
        s32p: 32,
        flt: 32,
        fltp: 32,
        s64: 64,
        s64p: 64,
        dbl: 64,
        dblp: 64
    };
    if (knownBitDepth[sampleFormat]) {
        return knownBitDepth[sampleFormat];
    }

    const match = sampleFormat.match(/([0-9]{1,3})/);
    if (!match) return null;
    const parsed = Number(match[1]);
    if (!Number.isFinite(parsed) || parsed <= 0) return null;
    return parsed;
}

function formatBitDepth(song) {
    const directCandidates = [
        song?.bitDepth,
        song?.bit_depth,
        song?.bitsPerSample,
        song?.bits_per_sample,
        song?.bitsPerRawSample,
        song?.bits_per_raw_sample
    ];

    for (const candidate of directCandidates) {
        const bitDepth = parsePositiveNumber(candidate);
        if (bitDepth) {
            return `${Math.round(bitDepth)} bit`;
        }
    }

    const sampleFormatCandidates = [
        song?.sampleFormat,
        song?.sample_fmt
    ];
    for (const candidate of sampleFormatCandidates) {
        const parsedBitDepth = parseBitDepthFromSampleFormat(candidate);
        if (parsedBitDepth) {
            return `${parsedBitDepth} bit`;
        }
    }

    return '-';
}

function formatAudioFormat(song) {
    const candidates = [
        song?.fileType,
        song?.format,
        song?.container,
        song?.codec
    ];

    for (const candidate of candidates) {
        if (typeof candidate !== 'string') continue;
        const trimmed = candidate.trim();
        if (!trimmed) continue;
        return trimmed.replace(/^\./, '').toUpperCase();
    }

    const path = typeof song?.path === 'string' ? song.path : '';
    const dotIndex = path.lastIndexOf('.');
    if (dotIndex !== -1 && dotIndex < path.length - 1) {
        return path.slice(dotIndex + 1).toUpperCase();
    }
    return '-';
}

function updateAudioInfoTooltip() {
    const sampleRateEl = document.getElementById('audio-info-sample-rate');
    const bitDepthEl = document.getElementById('audio-info-bit-depth');
    const formatEl = document.getElementById('audio-info-format');
    const audioInfoBtn = document.getElementById('audio-info-btn');
    if (!sampleRateEl || !bitDepthEl || !formatEl) return;

    const song = getCurrentQueueSong();
    if (!song) {
        sampleRateEl.textContent = '-';
        bitDepthEl.textContent = '-';
        formatEl.textContent = '-';
        audioInfoBtn?.classList.remove('hi-res');
        return;
    }

    sampleRateEl.textContent = formatSampleRate(song);
    bitDepthEl.textContent = formatBitDepth(song);
    formatEl.textContent = formatAudioFormat(song);

    // ハイレゾ判定: ロスレスフォーマット かつ (SR≥88200Hz または ビット深度>16bit)
    // MP3/MP4/AAC等は32bitと誤判定されることがあるため、フォーマットで除外
    const HI_RES_FORMATS = new Set(['FLAC', 'WAV', 'DSD', 'DSF', 'DFF', 'ALAC', 'AIFF', 'AIF']);
    const format = formatEl.textContent.toUpperCase();
    const isLossless = HI_RES_FORMATS.has(format);
    const sr = parsePositiveNumber(song?.sampleRate ?? song?.sample_rate) ?? 0;
    const bitDepthStr = bitDepthEl.textContent; // e.g. "24 bit"
    const bitDepth = parseInt(bitDepthStr, 10) || 0;
    const isHiRes = isLossless && (sr >= 88200 || bitDepth > 16);
    audioInfoBtn?.classList.toggle('hi-res', isHiRes);
}

// SVGパス定義（座標を配列で管理）
const PLAY_ICON = {
    part1: [[8, 5], [18, 12], [8, 12], [8, 5]],   // 三角形の上半分
    part2: [[8, 19], [18, 12], [8, 12], [8, 19]]  // 三角形の下半分
};
const PAUSE_ICON = {
    part1: [[6, 5], [10, 5], [10, 19], [6, 19]],  // 左の縦棒
    part2: [[14, 5], [18, 5], [18, 19], [14, 19]] // 右の縦棒
};

// パス座標を文字列に変換
function pathToString(points) {
    return `M ${points.map(p => p.join(' ')).join(' L ')} Z`;
}

// 2つのパス間を補間
function interpolatePath(from, to, progress) {
    return from.map((point, i) => [
        point[0] + (to[i][0] - point[0]) * progress,
        point[1] + (to[i][1] - point[1]) * progress
    ]);
}

// イージング関数（cubic-bezier(0.4, 0, 0.2, 1) の近似）
function easeOutCubic(t) {
    return 1 - Math.pow(1 - t, 3);
}

// SVGパスをアニメーションで変更
function animateIconPaths(iconPart1, iconPart2, toPlaying, duration = 250) {
    if (iconAnimationId) {
        cancelAnimationFrame(iconAnimationId);
    }

    const fromIcon = toPlaying ? PLAY_ICON : PAUSE_ICON;
    const toIcon = toPlaying ? PAUSE_ICON : PLAY_ICON;
    const startTime = performance.now();

    function animate(currentTime) {
        const elapsed = currentTime - startTime;
        const rawProgress = Math.min(elapsed / duration, 1);
        const progress = easeOutCubic(rawProgress);

        const currentPart1 = interpolatePath(fromIcon.part1, toIcon.part1, progress);
        const currentPart2 = interpolatePath(fromIcon.part2, toIcon.part2, progress);

        if (iconPart1) iconPart1.setAttribute('d', pathToString(currentPart1));
        if (iconPart2) iconPart2.setAttribute('d', pathToString(currentPart2));

        if (rawProgress < 1) {
            iconAnimationId = requestAnimationFrame(animate);
        } else {
            iconAnimationId = null;
        }
    }

    iconAnimationId = requestAnimationFrame(animate);
}


function updateUiTime(current, duration) {
    if (isNaN(duration) || duration <= 0) {
        elements.currentTimeEl.textContent = '0:00';
        elements.totalDurationEl.textContent = '0:00';
        elements.progressBar.max = 0;
        return;
    };
    elements.currentTimeEl.textContent = formatTime(current);
    elements.totalDurationEl.textContent = formatTime(duration);
    if (elements.progressBar.max != duration) elements.progressBar.max = duration;
}

function updateVolumeIcon() {
    const volume = parseFloat(elements.volumeSlider.value);
    const volumeIcon = document.getElementById('volume-icon');
    if (!volumeIcon) return;
    if (volume === 0) volumeIcon.src = './assets/icons/mute.svg';
    else if (volume < 0.5) volumeIcon.src = './assets/icons/small_sound.svg';
    else volumeIcon.src = './assets/icons/bigger_sound.svg';
}

function toggleMute() {
    const currentVolume = parseFloat(elements.volumeSlider.value);
    if (currentVolume > 0) {
        lastVolume = currentVolume;
        elements.volumeSlider.value = 0;
    } else {
        elements.volumeSlider.value = lastVolume > 0 ? lastVolume : 0.5;
    }
    elements.volumeSlider.dispatchEvent(new Event('input'));
}

function updateProgressBarLoop() {
    // シーク中はループを止める
    if (isSeeking) {
        progressFrameId = null;
        return;
    }

    // 再生中でない場合も止めるが、readyStateが低いだけの可能性もあるためガード
    if (!isPlaying()) {
        progressFrameId = null;
        return;
    }

    const currentTime = getCurrentTime();
    const duration = getDuration();

    if (elements.progressBar) {
        elements.progressBar.value = currentTime;
    }

    updateLrcEditorControls(true, currentTime, duration);
    progressFrameId = requestAnimationFrame(updateProgressBarLoop);
}

export function updateSeekUI(time) {
    const duration = getDuration();
    if (elements.progressBar) elements.progressBar.value = time;
    if (elements.currentTimeEl) elements.currentTimeEl.textContent = formatTime(time);
    updateLrcEditorControls(isPlaying(), time, duration);
}

export function initPlayerControls(initialPlayer, _callbacks) {
    elements.playPauseBtn.addEventListener('click', togglePlayPause);

    elements.progressBar.addEventListener('mousedown', () => {
        isSeeking = true;
        wasPlayingBeforeSeek = isPlaying();
        if (wasPlayingBeforeSeek) pauseCurrent(); // 汎用関数を使用
    });

    elements.progressBar.addEventListener('mouseup', () => {
        if (isSeeking) {
            const seekTime = parseFloat(elements.progressBar.value);
            seek(seekTime);
            isSeeking = false;
            if (wasPlayingBeforeSeek) {
                playCurrent(); // 汎用関数を使用
                wasPlayingBeforeSeek = false;
            }
            // ループは onplaying イベントから自動で再開されます
        }
    });

    elements.progressBar.addEventListener('input', () => {
        if (isSeeking) {
            const time = parseFloat(elements.progressBar.value);
            elements.currentTimeEl.textContent = formatTime(time);
            updateLrcEditorControls(false, time, getDuration());
        }
    });

    elements.volumeSlider.addEventListener('input', () => {
        const volume = parseFloat(elements.volumeSlider.value);
        if (window.go) {
            window.go.main.App.AudioSetVolume(volume).catch(() => { });
        } else {
            applyMasterVolume();
        }
        updateVolumeIcon();
    });

    elements.volumeSlider.addEventListener('change', () => {
        const volume = parseFloat(elements.volumeSlider.value);
        if (volumeSaveTimer) {
            clearTimeout(volumeSaveTimer);
        }

        volumeSaveTimer = setTimeout(() => {
            if (window.go) {
                window.go.main.App.SaveSettings({ volume: volume }).catch(() => { });
            } else {
                electronAPI.send('save-settings', { volume: volume });
            }
            volumeSaveTimer = null;
        }, 120);
    });

    document.getElementById('volume-icon-btn').addEventListener('click', toggleMute);

    const audioInfoBtn = document.getElementById('audio-info-btn');
    if (audioInfoBtn) {
        audioInfoBtn.addEventListener('mouseenter', updateAudioInfoTooltip);
        audioInfoBtn.addEventListener('focus', updateAudioInfoTooltip);
    }

    updateVolumeIcon();
    updateAudioInfoTooltip();
    initialiseShuffle();
}

/**
 * シャッフルアイコンを初期化する。
 * - 交差パス: 全長を dasharray に設定し、通常表示（dashoffset=0）に配置
 * - 三角矢印: offset-path でパス上の終端位置（100%）に配置
 */
function initialiseShuffle() {
    const btn = elements.shuffleBtn;
    if (!btn) return;

    const pathTop = btn.querySelector('.shuffle-path-top');
    const pathBottom = btn.querySelector('.shuffle-path-bottom');
    const headTop = btn.querySelector('.shuffle-head-top');
    const headBottom = btn.querySelector('.shuffle-head-bottom');
    if (!pathTop || !pathBottom) return;

    const topLen = pathTop.getTotalLength();
    const bottomLen = pathBottom.getTotalLength();
    pathTop.dataset.totalLength = topLen;
    pathBottom.dataset.totalLength = bottomLen;

    // ストロークを全長表示で配置（dashoffset=0 = パス終端にストロークの端が来る）
    pathTop.style.strokeDasharray = `${topLen} ${topLen * 3}`;
    pathTop.style.strokeDashoffset = '0';
    pathBottom.style.strokeDasharray = `${bottomLen} ${bottomLen * 3}`;
    pathBottom.style.strokeDashoffset = '0';

    // 矢印先端をパスの終端（100%）に配置
    if (headTop) {
        headTop.style.offsetPath = `path('${pathTop.getAttribute('d')}')`;
        headTop.style.offsetRotate = 'auto';
        headTop.style.offsetDistance = '100%';
    }
    if (headBottom) {
        headBottom.style.offsetPath = `path('${pathBottom.getAttribute('d')}')`;
        headBottom.style.offsetRotate = 'auto';
        headBottom.style.offsetDistance = '100%';
    }
}

/**
 * シャッフルボタン押下時のアニメーション。
 * 参考 HTML（shuffle_animation_image.html）と同様の実装:
 *   - 交差パス: strokeDashoffset でスライド
 *   - 三角矢印: offset-distance でパス上を移動
 * 動き: 右退場（200ms）→ 左ワープ → 左から再入場（400ms / spring）
 */
export async function runShuffleAnimation() {
    if (shuffleAnimationRunning) return;
    shuffleAnimationRunning = true;

    const btn = elements.shuffleBtn;
    if (!btn) { shuffleAnimationRunning = false; return; }

    const pathTop = btn.querySelector('.shuffle-path-top');
    const pathBottom = btn.querySelector('.shuffle-path-bottom');
    const headTop = btn.querySelector('.shuffle-head-top');
    const headBottom = btn.querySelector('.shuffle-head-bottom');
    if (!pathTop || !pathBottom) { shuffleAnimationRunning = false; return; }

    const topLen = parseFloat(pathTop.dataset.totalLength) || pathTop.getTotalLength();
    const bottomLen = parseFloat(pathBottom.dataset.totalLength) || pathBottom.getTotalLength();

    // 位置定義（参考 HTML の posStandard / posExit / posEnter に相当）
    const posStandard = 100;  // 通常: パス終端
    const posExit = 130;      // 退出: パス終端を 30% 超えた位置（SVG 外へ）
    const posEnter = -30;     // 入場: パス始端の 30% 手前（SVG 外から）

    // dashoffset = arrowLen - (pos/100) * pathLen  （参考 HTML と同式）
    const dashOf = (pos, len) => len - (pos / 100) * len;

    const timingExit  = { duration: 200, easing: 'ease-in', fill: 'forwards' };
    const timingEnter = { duration: 400, easing: 'cubic-bezier(0.16, 1, 0.3, 1)', fill: 'forwards' };

    // 1. 右側へ高速退出（ストローク + 矢印先端 を同時に）
    const exitAnims = [
        pathTop.animate(
            [{ strokeDashoffset: dashOf(posStandard, topLen) }, { strokeDashoffset: dashOf(posExit, topLen) }],
            timingExit
        ),
        pathBottom.animate(
            [{ strokeDashoffset: dashOf(posStandard, bottomLen) }, { strokeDashoffset: dashOf(posExit, bottomLen) }],
            timingExit
        ),
    ];
    if (headTop) exitAnims.push(
        headTop.animate(
            [{ offsetDistance: `${posStandard}%` }, { offsetDistance: `${posExit}%` }],
            timingExit
        )
    );
    if (headBottom) exitAnims.push(
        headBottom.animate(
            [{ offsetDistance: `${posStandard}%` }, { offsetDistance: `${posExit}%` }],
            timingExit
        )
    );
    await Promise.all(exitAnims.map(a => a.finished));

    // 2. 左端へ瞬間ワープ
    pathTop.style.strokeDashoffset = dashOf(posEnter, topLen);
    pathBottom.style.strokeDashoffset = dashOf(posEnter, bottomLen);
    if (headTop) headTop.style.offsetDistance = `${posEnter}%`;
    if (headBottom) headBottom.style.offsetDistance = `${posEnter}%`;

    // 3. 左側から軽快に再入場
    const enterAnims = [
        pathTop.animate(
            [{ strokeDashoffset: dashOf(posEnter, topLen) }, { strokeDashoffset: dashOf(posStandard, topLen) }],
            timingEnter
        ),
        pathBottom.animate(
            [{ strokeDashoffset: dashOf(posEnter, bottomLen) }, { strokeDashoffset: dashOf(posStandard, bottomLen) }],
            timingEnter
        ),
    ];
    if (headTop) enterAnims.push(
        headTop.animate(
            [{ offsetDistance: `${posEnter}%` }, { offsetDistance: `${posStandard}%` }],
            timingEnter
        )
    );
    if (headBottom) enterAnims.push(
        headBottom.animate(
            [{ offsetDistance: `${posEnter}%` }, { offsetDistance: `${posStandard}%` }],
            timingEnter
        )
    );
    await Promise.all(enterAnims.map(a => a.finished));

    // 状態を確定
    pathTop.style.strokeDashoffset = String(dashOf(posStandard, topLen));
    pathBottom.style.strokeDashoffset = String(dashOf(posStandard, bottomLen));
    if (headTop) headTop.style.offsetDistance = `${posStandard}%`;
    if (headBottom) headBottom.style.offsetDistance = `${posStandard}%`;

    shuffleAnimationRunning = false;
}

export function updatePlaybackStateUI(playing) {
    const currentTime = getCurrentTime();
    const duration = getDuration();

    // SVGアイコンをモーフィングアニメーションで更新（Wails webviewのCSS d プロパティ非対応に対応）
    const iconPart1 = elements.playPauseBtn.querySelector('.icon-part-1');
    const iconPart2 = elements.playPauseBtn.querySelector('.icon-part-2');

    // シーク中でなければアニメーション実行
    if (!isSeeking || playing) {
        animateIconPaths(iconPart1, iconPart2, playing);
    }

    if (playing) {
        elements.playPauseBtn.classList.add('playing');
        if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'playing';
        updateLrcEditorControls(true, currentTime, duration);

        if (progressUpdateInterval) clearInterval(progressUpdateInterval);
        progressUpdateInterval = setInterval(() => {
            if (!isSeeking) updateUiTime(getCurrentTime(), getDuration());
        }, 1000);

        // 二重起動防止
        if (!progressFrameId) {
            progressFrameId = requestAnimationFrame(updateProgressBarLoop);
        }

    } else {
        if (!isSeeking) {
            elements.playPauseBtn.classList.remove('playing');
        }
        if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'paused';
        updateLrcEditorControls(false, currentTime, duration);

        if (progressUpdateInterval) {
            clearInterval(progressUpdateInterval);
            progressUpdateInterval = null;
        }

        if (progressFrameId) {
            cancelAnimationFrame(progressFrameId);
            progressFrameId = null;
        }
    }
}

export function updateMetadataUI() {
    const duration = getDuration();
    elements.totalDurationEl.textContent = formatTime(duration);
    elements.progressBar.max = duration;
    updateLrcEditorControls(isPlaying(), getCurrentTime(), duration);
    updateAudioInfoTooltip();
}

export function resetPlaybackUI() {
    elements.currentTimeEl.textContent = '0:00';
    elements.totalDurationEl.textContent = '0:00';
    elements.progressBar.value = 0;
    elements.progressBar.max = 0;
    updateLrcEditorControls(false, 0, 0);

    if (progressUpdateInterval) {
        clearInterval(progressUpdateInterval);
        progressUpdateInterval = null;
    }

    if (progressFrameId) {
        cancelAnimationFrame(progressFrameId);
        progressFrameId = null;
    }

    updateAudioInfoTooltip();
}
