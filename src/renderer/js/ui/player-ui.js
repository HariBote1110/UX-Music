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

function parseBitrateToKbps(value) {
    const numeric = parsePositiveNumber(value);
    if (numeric) {
        return numeric >= 1000 ? numeric / 1000 : numeric;
    }

    if (typeof value !== 'string') return null;
    const text = value.trim().toLowerCase();
    if (!text) return null;

    const match = text.match(/([0-9]+(?:\.[0-9]+)?)\s*(kbps|kb\/s|k|mbps|mb\/s|m|bps)?/i);
    if (!match) return null;

    const amount = Number(match[1]);
    if (!Number.isFinite(amount) || amount <= 0) return null;

    const unit = (match[2] || '').toLowerCase();
    if (unit.startsWith('m')) return amount * 1000;
    if (unit === 'bps') return amount / 1000;
    return amount;
}

function formatBitrate(song) {
    const directCandidates = [
        song?.bitrate,
        song?.bitRate,
        song?.bit_rate,
        song?.bitrateKbps,
        song?.bitrate_kbps
    ];

    for (const candidate of directCandidates) {
        const kbps = parseBitrateToKbps(candidate);
        if (kbps) {
            return `${Math.round(kbps)} kbps`;
        }
    }

    const duration = parsePositiveNumber(song?.duration);
    const fileSize = parsePositiveNumber(song?.fileSize);
    if (duration && fileSize) {
        const estimatedKbps = (fileSize * 8) / duration / 1000;
        if (Number.isFinite(estimatedKbps) && estimatedKbps > 0) {
            return `~${Math.round(estimatedKbps)} kbps`;
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
    const bitrateEl = document.getElementById('audio-info-bitrate');
    const formatEl = document.getElementById('audio-info-format');
    if (!sampleRateEl || !bitrateEl || !formatEl) return;

    const song = getCurrentQueueSong();
    if (!song) {
        sampleRateEl.textContent = '-';
        bitrateEl.textContent = '-';
        formatEl.textContent = '-';
        return;
    }

    sampleRateEl.textContent = formatSampleRate(song);
    bitrateEl.textContent = formatBitrate(song);
    formatEl.textContent = formatAudioFormat(song);
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

    elements.volumeSlider.addEventListener('input', async () => {
        const volume = parseFloat(elements.volumeSlider.value);
        if (window.go) {
            await window.go.main.App.AudioSetVolume(volume);
            await window.go.main.App.SaveSettings({ volume: volume });
        } else {
            applyMasterVolume();
            electronAPI.send('save-settings', { volume: volume });
        }
        updateVolumeIcon();
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
