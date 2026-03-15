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
}

/**
 * シャッフルボタン押下時のアニメーションを実行する。
 * SVG に overflow: hidden のクリップ領域を設け、
 * アイコン全体を <g> ごと translateX + opacity で動かす。
 *   1. 少し右へスライドしながらフェードアウト
 *   2. 左端へ瞬間ワープ
 *   3. 左端から滑り込んでフェードイン
 */
export async function runShuffleAnimation() {
    if (shuffleAnimationRunning) return;
    shuffleAnimationRunning = true;

    const btn = elements.shuffleBtn;
    if (!btn) { shuffleAnimationRunning = false; return; }

    const group = btn.querySelector('.shuffle-icon-group');
    if (!group) { shuffleAnimationRunning = false; return; }

    // SVG の実際のレンダリング幅を取得し、左端ワープ距離を決定
    const svgEl = btn.querySelector('svg');
    const svgWidth = svgEl ? svgEl.getBoundingClientRect().width : 22;
    const enterFrom = -(svgWidth + 2); // SVG 幅 + 余白 2px 分だけ左へ

    // 1. ほんのちょっと右へ動いてフェードアウト
    const exitAnim = group.animate(
        [
            { transform: 'translateX(0px)', opacity: 1 },
            { transform: 'translateX(5px)', opacity: 0 },
        ],
        { duration: 130, easing: 'ease-in', fill: 'forwards' }
    );
    await exitAnim.finished;
    exitAnim.cancel();

    // 2. 左端へ瞬間ワープ（アニメーションなし）
    group.style.transform = `translateX(${enterFrom}px)`;
    group.style.opacity = '0';

    // 3. 左側から滑り込んでフェードイン
    const enterAnim = group.animate(
        [
            { transform: `translateX(${enterFrom}px)`, opacity: 0 },
            { transform: 'translateX(0px)', opacity: 1 },
        ],
        { duration: 340, easing: 'cubic-bezier(0.16, 1, 0.3, 1)', fill: 'forwards' }
    );
    await enterAnim.finished;
    enterAnim.cancel();

    // 状態を確定（アニメーション由来のスタイルをリセット）
    group.style.transform = '';
    group.style.opacity = '';

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
