import { state, elements } from '../core/state.js';
import { renderGraphicEQ } from '../ui/equalizer.js';
import { renderCurrentView, updateAudioDevices } from '../ui/ui-manager.js';
import { setVisualizerFpsLimit } from '../features/player.js';
import { updateNowPlayingView } from '../ui/now-playing.js';
import { showNotification, hideNotification } from '../ui/notification.js';
import { initPlaybackSettings } from '../features/playback-manager.js';
import { musicApi, getWailsApp } from '../core/bridge.js';
import { loadRendererSettings } from '../core/settings-helpers.js';
import { updateListSpacer } from '../ui/ui.js';
import { formatSyncPeerEndpoint, formatSyncPeerRoles, normaliseSyncPeers, type SyncPeer } from '../features/ux-sync-settings.js';
const electronAPI = window.electronAPI;

/**
 * 指定したテーマを body クラスに適用する。
 * 現状サポートするテーマ: 'default' | 'music-center'
 */
export function applyUiTheme(theme: string): void {
    document.body.classList.toggle('mc-theme', theme === 'music-center');
    // 再生バーの位置が変わるためスペーサーを再計算する
    requestAnimationFrame(() => updateListSpacer());
}

const decaySliderValues = [1, 3, 7, 14, 30];
const decaySliderLabels = ['1日', '3日', '7日', '2週間', '1ヶ月'];

function formatBytesJp(bytes: number): string {
    if (!Number.isFinite(bytes) || bytes < 0) {
        return '不明';
    }
    if (bytes < 1024) {
        return `${Math.round(bytes)} B`;
    }
    const units = ['KB', 'MB', 'GB'];
    let u = -1;
    let n = bytes;
    do {
        n /= 1024;
        u += 1;
    } while (n >= 1024 && u < units.length - 1);
    return `${n.toFixed(1)} ${units[u]}`;
}

async function refreshLyricsSyncCacheInfo() {
    const el = document.getElementById('lyrics-sync-cache-info');
    const consentCb = document.getElementById('lyrics-sync-model-consent') as HTMLInputElement | null;
    const app = getWailsApp();
    if (!el) {
        return;
    }
    if (!app?.GetLyricsSyncResourceStatus) {
        el.textContent = '（歌詞同期モデル情報は Wails バックエンドでのみ利用できます）';
        if (consentCb) consentCb.disabled = true;
        return;
    }
    if (consentCb) consentCb.disabled = false;
    try {
        const st = await app.GetLyricsSyncResourceStatus();
        const bytes = Number((st as { cacheBytes?: number }).cacheBytes ?? 0);
        const path = String((st as { cachePath?: string }).cachePath ?? '');
        const consent = Boolean((st as { modelConsent?: boolean }).modelConsent);
        el.textContent = `モデルキャッシュ: ${formatBytesJp(bytes)}（ダウンロード同意: ${consent ? '済' : '未'}）／${path}`;
        if (consentCb) consentCb.checked = consent;
    } catch {
        el.textContent = '同期モデル情報の取得に失敗しました。';
    }
}

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

async function refreshUxSyncPeers() {
    const group = document.getElementById('ux-sync-discovery-group');
    const btn = document.getElementById('ux-sync-discover-btn') as HTMLButtonElement | null;
    const statusEl = document.getElementById('ux-sync-discovery-status');
    const listEl = document.getElementById('ux-sync-peer-list');
    if (!group || !btn || !statusEl || !listEl) return;

    if (!getWailsApp()?.DiscoverSyncDevices) {
        group.classList.add('hidden');
        return;
    }

    group.classList.remove('hidden');
    btn.disabled = true;
    btn.textContent = '探索中...';
    statusEl.textContent = 'LAN内のUX Musicを探索しています。';
    listEl.innerHTML = '';

    try {
        const peers = normaliseSyncPeers(await musicApi.discoverSyncDevices(2500));
        renderUxSyncPeers(listEl, peers);
        statusEl.textContent = peers.length > 0
            ? `${peers.length}台の同期端末を検出しました。`
            : '同期端末は見つかりませんでした。';
    } catch (e) {
        const msg = (e as Error)?.message || String(e);
        statusEl.textContent = `探索に失敗しました: ${msg}`;
    } finally {
        btn.disabled = false;
        btn.textContent = '同期端末を探す';
    }
}

function renderUxSyncPeers(listEl: HTMLElement, peers: SyncPeer[]) {
    listEl.innerHTML = '';
    for (const peer of peers) {
        const item = document.createElement('div');
        item.className = 'ux-sync-peer-item';

        const name = document.createElement('div');
        name.className = 'ux-sync-peer-name';
        const title = document.createElement('span');
        title.textContent = peer.displayName;
        const stateLabel = document.createElement('span');
        stateLabel.className = 'ux-sync-peer-state';
        stateLabel.textContent = peer.reachableBaseUrl ? '接続候補' : '未確認';
        name.append(title, stateLabel);

        const endpoint = document.createElement('div');
        endpoint.className = 'ux-sync-peer-meta';
        endpoint.textContent = formatSyncPeerEndpoint(peer);

        const roles = document.createElement('div');
        roles.className = 'ux-sync-peer-meta';
        roles.textContent = formatSyncPeerRoles(peer);

        const hosts = document.createElement('div');
        hosts.className = 'ux-sync-peer-meta';
        hosts.textContent = peer.hosts.length > 0 ? peer.hosts.join(' / ') : '候補アドレスなし';

        item.append(name, endpoint, roles, hosts);
        listEl.appendChild(item);
    }
}

export function initSettings() {
    // Initialise playback settings from storage
    initPlaybackSettings();

    // 起動時にユーザーが選択したUIテーマを復元する
    void loadRendererSettings().then(settings => {
        applyUiTheme(settings.uiTheme || 'default');
    });

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

        const currentUiTheme = settings.uiTheme || 'default';
        (document.querySelector(`input[name="ui-theme"][value="${currentUiTheme}"]`) as HTMLInputElement).checked = true;

        const lyricsConsentCb = document.getElementById('lyrics-sync-model-consent') as HTMLInputElement | null;
        if (lyricsConsentCb) {
            let consentVal = Boolean((settings as { lyricsSyncModelConsent?: boolean }).lyricsSyncModelConsent);
            const wailsApp = getWailsApp();
            if (wailsApp?.GetLyricsSyncResourceStatus) {
                try {
                    const st = await wailsApp.GetLyricsSyncResourceStatus();
                    const mc = (st as { modelConsent?: boolean }).modelConsent;
                    if (typeof mc === 'boolean') {
                        consentVal = mc;
                    }
                } catch {
                    /* leave consentVal from stored settings */
                }
            }
            lyricsConsentCb.checked = consentVal;
            lyricsConsentCb.disabled = !wailsApp?.GetLyricsSyncResourceStatus;
        }

        elements.settingsModalOverlay.classList.remove('hidden');
        void refreshWearPairingQR();
        void refreshUxSyncPeers();
        void refreshLyricsSyncCacheInfo();

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
        const lyricsModelConsentCb = document.getElementById('lyrics-sync-model-consent') as HTMLInputElement | null;

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
            lyricsSyncModelConsent: lyricsModelConsentCb?.checked === true,
            uiTheme: (document.querySelector('input[name="ui-theme"]:checked') as HTMLInputElement).value,
            // Maintain current playback state during settings save
            isShuffled: state.isShuffled,
            playbackMode: state.playbackMode
        };

        electronAPI.send('save-settings', settingsToSave);

        const wails = getWailsApp();
        if (wails?.SetLyricsSyncModelConsent) {
            void wails.SetLyricsSyncModelConsent(settingsToSave.lyricsSyncModelConsent).catch(() => {});
        }

        state.visualizerMode = settingsToSave.visualizerMode;
        state.analysedQueue = settingsToSave.analysedQueue;

        applyUiTheme(settingsToSave.uiTheme);

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

    const syncDiscoverBtn = document.getElementById('ux-sync-discover-btn');
    if (syncDiscoverBtn && !syncDiscoverBtn.dataset.listenerAttached) {
        syncDiscoverBtn.addEventListener('click', () => {
            void refreshUxSyncPeers();
        });
        syncDiscoverBtn.dataset.listenerAttached = 'true';
    }

    const clearLyricsBtn = document.getElementById('lyrics-sync-cache-clear-btn');
    if (clearLyricsBtn && !clearLyricsBtn.dataset.listenerAttached) {
        clearLyricsBtn.addEventListener('click', async () => {
            const app = getWailsApp();
            if (!app?.ClearLyricsSyncModelCache) {
                showNotification('この環境ではキャッシュ削除を実行できません。');
                hideNotification(4000);
                return;
            }
            if (!window.confirm('歌詞同期用のダウンロード済みモデルを削除します。よろしいですか？')) {
                return;
            }
            try {
                await app.ClearLyricsSyncModelCache();
                showNotification('同期モデルキャッシュを削除しました。');
                hideNotification(3000);
                await refreshLyricsSyncCacheInfo();
            } catch (e) {
                showNotification(`削除に失敗しました: ${(e as Error)?.message || String(e)}`);
                hideNotification(5000);
            }
        });
        clearLyricsBtn.dataset.listenerAttached = 'true';
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
