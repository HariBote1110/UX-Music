// src/renderer/js/player-ui.js

import { elements, state } from './state.js';
import { updateLrcEditorControls } from './lrc-editor.js';
import {
    seek,
    togglePlayPause,
    isPlaying,
    getCurrentTime,
    getDuration,
    playCurrent,
    pauseCurrent
} from './player.js';
import { applyMasterVolume } from './audio-graph.js';
import { formatTime } from './ui/utils.js';
const electronAPI = window.electronAPI;

let isSeeking = false;
let wasPlayingBeforeSeek = false;
let progressUpdateInterval = null;
let progressFrameId = null;
let lastVolume = 0.5;
let iconAnimationId = null;

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

export function initPlayerControls(initialPlayer, callbacks) {
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

    updateVolumeIcon();

    if ('mediaSession' in navigator) {
        navigator.mediaSession.setActionHandler('play', togglePlayPause);
        navigator.mediaSession.setActionHandler('pause', togglePlayPause);
        if (callbacks.onNextSong) navigator.mediaSession.setActionHandler('nexttrack', callbacks.onNextSong);
        if (callbacks.onPrevSong) navigator.mediaSession.setActionHandler('previoustrack', callbacks.onPrevSong);
    }
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
}