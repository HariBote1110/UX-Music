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
const { ipcRenderer } = require('electron');

let isSeeking = false;
let wasPlayingBeforeSeek = false;
let progressUpdateInterval = null; 
let progressFrameId = null; 
let lastVolume = 0.5; 


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

    elements.volumeSlider.addEventListener('input', () => {
        applyMasterVolume(); 
        updateVolumeIcon();
        ipcRenderer.send('save-settings', { volume: parseFloat(elements.volumeSlider.value) });
    });

    document.getElementById('volume-icon-btn').addEventListener('click', toggleMute);

    updateVolumeIcon();

    if ('mediaSession' in navigator) {
        navigator.mediaSession.setActionHandler('play', togglePlayPause);
        navigator.mediaSession.setActionHandler('pause', togglePlayPause);
        if(callbacks.onNextSong) navigator.mediaSession.setActionHandler('nexttrack', callbacks.onNextSong);
        if(callbacks.onPrevSong) navigator.mediaSession.setActionHandler('previoustrack', callbacks.onPrevSong);
    }
}

export function updatePlaybackStateUI(playing) {
    const currentTime = getCurrentTime();
    const duration = getDuration();

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
        if (!isSeeking) elements.playPauseBtn.classList.remove('playing');
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