import { state, elements } from '../core/state.js';
import { renderGraphicEQ } from '../ui/equalizer.js';
import { renderCurrentView, updateAudioDevices } from '../ui/ui-manager.js';
import { setVisualizerFpsLimit } from '../features/player.js';
import { updateNowPlayingView } from '../ui/now-playing.js';
import { showNotification, hideNotification } from '../ui/notification.js';
import { initPlaybackSettings } from '../features/playback-manager.js';
import { musicApi } from '../core/bridge.js';
import {
    applyTitleListMinWidthPref,
    formatTitleListMinWidthLabel,
    getTitleListMinWidthPx,
    persistTitleListMinWidthPx,
} from '../ui/text-layout-prefs.js';
const electronAPI = window.electronAPI;

const decaySliderValues = [1, 3, 7, 14, 30];
const decaySliderLabels = ['1日', '3日', '7日', '2週間', '1ヶ月'];

async function refreshWearPairingQR() {
    const group = document.getElementById('wear-mobile-pairing-group');
    const wrap = document.getElementById('wear-pairing-qr-wrap');
    const img = document.getElementById('wear-pairing-qr');
    const urlEl = document.getElementById('wear-pairing-url');
    const errEl = document.getElementById('wear-pairing-qr-error');
    if (!group || !wrap || !img || !errEl) return;
    errEl.classList.add('hidden');
    errEl.textContent = '';
    if (!window.go?.main?.App?.GetWearPairingQRDataURL) {
        group.classList.add('hidden');
        return;
    }
    group.classList.remove('hidden');
    try {
        const dataUrl = await window.go.main.App.GetWearPairingQRDataURL();
        img.src = dataUrl;
        wrap.classList.remove('hidden');
        if (urlEl && window.go.main.App.GetWearPairingURL) {
            urlEl.textContent = await window.go.main.App.GetWearPairingURL();
        }
    } catch (e) {
        wrap.classList.add('hidden');
        const msg = e?.message || String(e);
        errEl.textContent = 'QR の生成に失敗しました: ' + msg;
        errEl.classList.remove('hidden');
    }
}

export function initSettings() {
    // Initialise playback settings from storage
    initPlaybackSettings();

    let settingsClickCount = 0;
    let settingsClickTimer;

    elements.openSettingsBtn.addEventListener('click', async () => {
        const settings = await electronAPI.invoke('get-settings');

        renderGraphicEQ();

        const currentYoutubeMode = settings.youtubePlaybackMode || 'download';
        document.querySelector(`input[name="youtube-mode"][value="${currentYoutubeMode}"]`).checked = true;

        const currentQuality = settings.youtubeDownloadQuality || 'full';
        document.querySelector(`input[name="youtube-quality"][value="${currentQuality}"]`).checked = true;

        updateQualityGroupState();

        const currentImportMode = settings.importMode || 'balanced';
        document.querySelector(`input[name="import-mode"][value="${currentImportMode}"]`).checked = true;

        const currentCdRipMode = settings.cdRipMode || 'paranoia';
        document.querySelector(`input[name="cd-rip-mode"][value="${currentCdRipMode}"]`).checked = true;

        const currentVisualizerMode = settings.visualizerMode || 'active';
        document.querySelector(`input[name="visualizer-mode"][value="${currentVisualizerMode}"]`).checked = true;

        document.querySelector('input[name="group-album-art"]').checked = settings.groupAlbumArt === true;

        const titleListSlider = document.getElementById('title-list-min-width-slider');
        const titleListValueLabel = document.getElementById('title-list-min-width-value');
        if (titleListSlider && titleListValueLabel) {
            const tw = getTitleListMinWidthPx();
            titleListSlider.value = String(tw);
            titleListValueLabel.textContent = formatTitleListMinWidthLabel(tw);
        }

        const analysedQueueEnabled = settings.analysedQueue?.enabled === true;
        const analysedQueueCheckbox = document.querySelector('input[name="enable-analysed-queue"]');
        analysedQueueCheckbox.checked = analysedQueueEnabled;
        document.getElementById('analysed-queue-options').classList.toggle('hidden', !analysedQueueEnabled);

        const currentDecayDays = settings.analysedQueue?.decayDays || 7;
        const decaySlider = document.getElementById('analysed-queue-decay-slider');
        const decayValueLabel = document.getElementById('analysed-queue-decay-value');
        const sliderIndex = decaySliderValues.indexOf(currentDecayDays);
        decaySlider.value = sliderIndex > -1 ? sliderIndex : 2;
        decayValueLabel.textContent = decaySliderLabels[decaySlider.value];

        document.querySelector('input[name="enable-easter-eggs"]').checked = settings.enableEasterEggs !== false;

        elements.settingsModalOverlay.classList.remove('hidden');
        void refreshWearPairingQR();

        const settingsTitle = document.getElementById('settings-title');
        if (settingsTitle && !settingsTitle.dataset.listenerAttached) {
            settingsTitle.addEventListener('click', () => {
                clearTimeout(settingsClickTimer);
                settingsClickCount++;
                if (settingsClickCount >= 7) {
                    const quizBtn = document.getElementById('quiz-view-btn');
                    if (quizBtn) {
                        quizBtn.classList.remove('hidden');
                        showNotification('隠し機能がアンロックされました！');
                        hideNotification(3000);
                    }
                    settingsClickCount = 0;
                }
                settingsClickTimer = setTimeout(() => { settingsClickCount = 0; }, 1000);
            });
            settingsTitle.dataset.listenerAttached = 'true';
        }
    });

    document.querySelectorAll('input[name="youtube-mode"]').forEach(radio => {
        radio.addEventListener('change', updateQualityGroupState);
    });

    document.querySelector('input[name="enable-analysed-queue"]').addEventListener('change', (e) => {
        document.getElementById('analysed-queue-options').classList.toggle('hidden', !e.target.checked);
    });

    document.getElementById('analysed-queue-decay-slider').addEventListener('input', (e) => {
        document.getElementById('analysed-queue-decay-value').textContent = decaySliderLabels[e.target.value];
    });

    const titleListSlider = document.getElementById('title-list-min-width-slider');
    const titleListValueLabel = document.getElementById('title-list-min-width-value');
    if (titleListSlider && titleListValueLabel) {
        titleListSlider.addEventListener('input', () => {
            const px = parseInt(titleListSlider.value, 10) || 0;
            titleListValueLabel.textContent = formatTitleListMinWidthLabel(px);
            document.documentElement.style.setProperty(
                '--song-title-list-min-px',
                px > 0 ? `${px}px` : '0px'
            );
        });
    }

    elements.settingsOkBtn.addEventListener('click', () => {
        const decaySliderValue = document.getElementById('analysed-queue-decay-slider').value;
        const settingsToSave = {
            youtubePlaybackMode: document.querySelector('input[name="youtube-mode"]:checked').value,
            youtubeDownloadQuality: document.querySelector('input[name="youtube-quality"]:checked').value,
            importMode: document.querySelector('input[name="import-mode"]:checked').value,
            cdRipMode: document.querySelector('input[name="cd-rip-mode"]:checked').value,
            visualizerMode: document.querySelector('input[name="visualizer-mode"]:checked').value,
            groupAlbumArt: document.querySelector('input[name="group-album-art"]').checked,
            analysedQueue: {
                enabled: document.querySelector('input[name="enable-analysed-queue"]').checked,
                decayDays: decaySliderValues[decaySliderValue]
            },
            enableEasterEggs: document.querySelector('input[name="enable-easter-eggs"]').checked,
            // Maintain current playback state during settings save
            isShuffled: state.isShuffled,
            playbackMode: state.playbackMode
        };

        electronAPI.send('save-settings', settingsToSave);

        if (titleListSlider) {
            persistTitleListMinWidthPx(parseInt(titleListSlider.value, 10) || 0);
        } else {
            applyTitleListMinWidthPref();
        }

        state.visualizerMode = settingsToSave.visualizerMode;
        if (state.groupAlbumArt !== settingsToSave.groupAlbumArt) {
            state.groupAlbumArt = settingsToSave.groupAlbumArt;
            renderCurrentView();
        }
        state.analysedQueue = settingsToSave.analysedQueue;

        elements.settingsModalOverlay.classList.add('hidden');
    });

    let userPreferredVisualizerMode = 'active';

    elements.lightFlightModeBtn.addEventListener('click', () => {
        state.isLightFlightMode = !state.isLightFlightMode;
        document.body.classList.toggle('light-flight-mode', state.isLightFlightMode);
        elements.lightFlightModeBtn.classList.toggle('active', state.isLightFlightMode);

        if (state.isLightFlightMode) {
            userPreferredVisualizerMode = state.visualizerMode;
            state.visualizerMode = 'static';
            state.userPreferredVisualizerFps = state.visualizerFpsLimit;
            setVisualizerFpsLimit(30);
        } else {
            state.visualizerMode = userPreferredVisualizerMode;
            setVisualizerFpsLimit(state.userPreferredVisualizerFps);
        }

        renderCurrentView();
        updateNowPlayingView(state.playbackQueue[state.currentSongIndex]);
    });

    document.getElementById('manage-devices-btn').addEventListener('click', async () => {
        const devices = await navigator.mediaDevices.enumerateDevices();
        const audioDevices = devices.filter(d => d.kind === 'audiooutput');
        const settings = await electronAPI.invoke('get-settings');
        const hiddenDevices = settings.hiddenDeviceIds || [];

        const listEl = document.getElementById('devices-list');
        listEl.innerHTML = '';

        audioDevices.forEach(device => {
            const isHidden = hiddenDevices.includes(device.deviceId);
            const label = document.createElement('label');
            label.innerHTML = `<input type="checkbox" data-device-id="${device.deviceId}" ${!isHidden ? 'checked' : ''}><span>${device.label || `スピーカー ${audioDevices.indexOf(device) + 1}`}</span>`;
            listEl.appendChild(label);
        });

        document.getElementById('devices-modal-overlay').classList.remove('hidden');
    });

    document.getElementById('devices-ok-btn').addEventListener('click', () => {
        const hiddenDeviceIds = Array.from(document.querySelectorAll('#devices-list input:not(:checked)')).map(cb => cb.dataset.deviceId);
        electronAPI.send('save-settings', { hiddenDeviceIds });
        document.getElementById('devices-modal-overlay').classList.add('hidden');
        updateAudioDevices();
    });

    const buildFlacBtn = document.getElementById('build-flac-indexes-btn');
    if (buildFlacBtn) {
        buildFlacBtn.addEventListener('click', () => {
            buildFlacBtn.disabled = true;
            buildFlacBtn.textContent = '構築中...';
            musicApi.buildFLACIndexes();
        });
    }
}

function updateQualityGroupState() {
    const youtubeMode = document.querySelector('input[name="youtube-mode"]:checked')?.value;
    const qualityGroup = document.getElementById('youtube-quality-group');
    if (youtubeMode === 'stream') {
        qualityGroup.classList.add('disabled');
        document.querySelectorAll('input[name="youtube-quality"]').forEach(radio => radio.disabled = true);
    } else {
        qualityGroup.classList.remove('disabled');
        document.querySelectorAll('input[name="youtube-quality"]').forEach(radio => radio.disabled = false);
    }
}