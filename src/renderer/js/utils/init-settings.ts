import { state, elements } from '../core/state.js';
import { renderGraphicEQ } from '../ui/equalizer.js';
import { renderCurrentView, updateAudioDevices } from '../ui/ui-manager.js';
import { setVisualizerFpsLimit } from '../features/player.js';
import { updateNowPlayingView } from '../ui/now-playing.js';
import { showNotification, hideNotification } from '../ui/notification.js';
import { initPlaybackSettings } from '../features/playback-manager.js';
import { musicApi, getWailsApp } from '../core/bridge.js';
import { loadRendererSettings } from '../core/settings-helpers.js';
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
    if (!getWailsApp()?.GetWearPairingQRDataURL) {
        group.classList.add('hidden');
        return;
    }
    group.classList.remove('hidden');
    try {
        const dataUrl = await getWailsApp().GetWearPairingQRDataURL();
        (img as HTMLImageElement).src = dataUrl;
        wrap.classList.remove('hidden');
        if (urlEl && getWailsApp()?.GetWearPairingURL) {
            urlEl.textContent = await getWailsApp().GetWearPairingURL();
        }
    } catch (e) {
        wrap.classList.add('hidden');
        const msg = (e as Error)?.message || String(e);
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
        const settings = await loadRendererSettings();

        renderGraphicEQ();

        const currentYoutubeMode = settings.youtubePlaybackMode || 'download';
        (document.querySelector(`input[name="youtube-mode"][value="${currentYoutubeMode}"]`) as HTMLInputElement).checked = true;

        const currentQuality = settings.youtubeDownloadQuality || 'full';
        (document.querySelector(`input[name="youtube-quality"][value="${currentQuality}"]`) as HTMLInputElement).checked = true;

        updateQualityGroupState();

        const currentImportMode = settings.importMode || 'balanced';
        (document.querySelector(`input[name="import-mode"][value="${currentImportMode}"]`) as HTMLInputElement).checked = true;

        const currentCdRipMode = settings.cdRipMode || 'paranoia';
        (document.querySelector(`input[name="cd-rip-mode"][value="${currentCdRipMode}"]`) as HTMLInputElement).checked = true;

        const currentVisualizerMode = settings.visualizerMode || 'active';
        (document.querySelector(`input[name="visualizer-mode"][value="${currentVisualizerMode}"]`) as HTMLInputElement).checked = true;

        // groupAlbumArt は常に有効のため設定項目から除外

        const analysedQueueEnabled = settings.analysedQueue?.enabled === true;
        const analysedQueueCheckbox = document.querySelector('input[name="enable-analysed-queue"]') as HTMLInputElement;
        analysedQueueCheckbox.checked = analysedQueueEnabled;
        document.getElementById('analysed-queue-options').classList.toggle('hidden', !analysedQueueEnabled);

        const currentDecayDays = settings.analysedQueue?.decayDays || 7;
        const decaySlider = document.getElementById('analysed-queue-decay-slider') as HTMLInputElement;
        const decayValueLabel = document.getElementById('analysed-queue-decay-value');
        const sliderIndex = decaySliderValues.indexOf(currentDecayDays);
        decaySlider.value = String(sliderIndex > -1 ? sliderIndex : 2);
        if (decayValueLabel) decayValueLabel.textContent = decaySliderLabels[parseInt(decaySlider.value)];

        (document.querySelector('input[name="enable-easter-eggs"]') as HTMLInputElement).checked = settings.enableEasterEggs !== false;

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

    (document.querySelector('input[name="enable-analysed-queue"]') as HTMLInputElement).addEventListener('change', (e) => {
        document.getElementById('analysed-queue-options')!.classList.toggle('hidden', !(e.target as HTMLInputElement).checked);
    });

    document.getElementById('analysed-queue-decay-slider')!.addEventListener('input', (e) => {
        const val = parseInt((e.target as HTMLInputElement).value);
        document.getElementById('analysed-queue-decay-value')!.textContent = decaySliderLabels[val];
    });

    elements.settingsOkBtn.addEventListener('click', () => {
        const decaySliderValue = parseInt((document.getElementById('analysed-queue-decay-slider') as HTMLInputElement).value);
        const settingsToSave = {
            youtubePlaybackMode: (document.querySelector('input[name="youtube-mode"]:checked') as HTMLInputElement).value,
            youtubeDownloadQuality: (document.querySelector('input[name="youtube-quality"]:checked') as HTMLInputElement).value,
            importMode: (document.querySelector('input[name="import-mode"]:checked') as HTMLInputElement).value,
            cdRipMode: (document.querySelector('input[name="cd-rip-mode"]:checked') as HTMLInputElement).value,
            visualizerMode: (document.querySelector('input[name="visualizer-mode"]:checked') as HTMLInputElement).value,

            analysedQueue: {
                enabled: (document.querySelector('input[name="enable-analysed-queue"]') as HTMLInputElement).checked,
                decayDays: decaySliderValues[decaySliderValue]
            },
            enableEasterEggs: (document.querySelector('input[name="enable-easter-eggs"]') as HTMLInputElement).checked,
            // Maintain current playback state during settings save
            isShuffled: state.isShuffled,
            playbackMode: state.playbackMode
        };

        electronAPI.send('save-settings', settingsToSave);

        state.visualizerMode = settingsToSave.visualizerMode;
        state.analysedQueue = settingsToSave.analysedQueue;

        elements.settingsModalOverlay.classList.add('hidden');
    });

    document.getElementById('manage-devices-btn').addEventListener('click', async () => {
        const devices = await navigator.mediaDevices.enumerateDevices();
        const audioDevices = devices.filter(d => d.kind === 'audiooutput');
        const settings = await loadRendererSettings();
        const hiddenDevices = (settings.hiddenDeviceIds as string[] | undefined) || [];

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
        const hiddenDeviceIds = Array.from(document.querySelectorAll('#devices-list input:not(:checked)')).map(cb => (cb as HTMLInputElement).dataset.deviceId);
        electronAPI.send('save-settings', { hiddenDeviceIds });
        document.getElementById('devices-modal-overlay').classList.add('hidden');
        updateAudioDevices();
    });

    const buildFlacBtn = document.getElementById('build-flac-indexes-btn') as HTMLButtonElement | null;
    if (buildFlacBtn) {
        buildFlacBtn.addEventListener('click', () => {
            buildFlacBtn.disabled = true;
            buildFlacBtn.textContent = '構築中...';
            musicApi.buildFLACIndexes();
        });
    }
}

function updateQualityGroupState() {
    const youtubeMode = (document.querySelector('input[name="youtube-mode"]:checked') as HTMLInputElement | null)?.value;
    const qualityGroup = document.getElementById('youtube-quality-group');
    if (youtubeMode === 'stream') {
        qualityGroup?.classList.add('disabled');
        document.querySelectorAll<HTMLInputElement>('input[name="youtube-quality"]').forEach(radio => radio.disabled = true);
    } else {
        qualityGroup?.classList.remove('disabled');
        document.querySelectorAll<HTMLInputElement>('input[name="youtube-quality"]').forEach(radio => radio.disabled = false);
    }
}
