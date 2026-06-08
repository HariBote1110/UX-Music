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
import {
    formatSyncPullResultSummary,
    formatSyncPushResultSummary,
    formatSyncPeerEndpoint,
    formatSyncPeerRoles,
    formatSyncTransferProgressSummary,
    mergeSyncPeersWithDevices,
    normaliseSyncDevices,
    normaliseSyncPairingConfirm,
    normaliseSyncPairingStart,
    normaliseSyncPullResult,
    normaliseSyncPushResult,
    normaliseSyncTransferProgress,
    normaliseSyncPeers,
    syncTransferEncodingOptions,
    syncPeerConnectionLabel,
    syncPullActionState,
    syncPushActionState,
    syncSettingsEntryState,
    syncPeerPairingBaseUrl,
    type SyncDevice,
    type SyncPairingStart,
    type SyncPeer,
} from '../features/ux-sync-settings.js';
const electronAPI = window.electronAPI;

let uxSyncPeers: SyncPeer[] = [];
let uxSyncDevices: SyncDevice[] = [];
let uxSyncTransferProgressUnsubscribe: (() => void) | null = null;

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
    const btn = document.getElementById('ux-sync-discover-btn') as HTMLButtonElement | null;
    const statusEl = document.getElementById('ux-sync-discovery-status');
    const listEl = document.getElementById('ux-sync-peer-list');
    if (!btn || !statusEl || !listEl) return;

    if (!getWailsApp()?.DiscoverSyncDevices && !getWailsApp()?.ListSyncDevices) {
        statusEl.textContent = 'この環境ではUX Syncを利用できません。';
        return;
    }

    btn.disabled = true;
    btn.textContent = '探索中...';
    statusEl.textContent = 'LAN内のUX Musicを探索しています。';
    listEl.innerHTML = '';

    try {
        const [rawPeers, devices] = await Promise.all([
            getWailsApp()?.DiscoverSyncDevices ? musicApi.discoverSyncDevices(2500) : Promise.resolve([]),
            loadUxSyncDevices(),
        ]);
        uxSyncDevices = devices;
        const peers = mergeSyncPeersWithDevices(normaliseSyncPeers(rawPeers), devices);
        uxSyncPeers = peers;
        renderUxSyncPeers(listEl, peers);
        refreshUxSyncTransferPeers();
        statusEl.textContent = peers.length > 0
            ? `${peers.length}台の同期端末を表示しています。`
            : '同期端末は見つかりませんでした。';
    } catch (e) {
        const msg = (e as Error)?.message || String(e);
        statusEl.textContent = `探索に失敗しました: ${msg}`;
    } finally {
        btn.disabled = false;
        btn.textContent = '同期端末を探す';
    }
}

async function loadUxSyncDevices(): Promise<SyncDevice[]> {
    if (!getWailsApp()?.ListSyncDevices) {
        return [];
    }
    try {
        return normaliseSyncDevices(await musicApi.listSyncDevices());
    } catch {
        return [];
    }
}

function updateUxSyncSettingsEntry() {
    const group = document.getElementById('ux-sync-settings-entry-group');
    const openBtn = document.getElementById('ux-sync-settings-open-btn') as HTMLButtonElement | null;
    const statusEl = document.getElementById('ux-sync-settings-entry-status');
    if (!group || !openBtn || !statusEl) return;

    const entry = syncSettingsEntryState(Boolean(getWailsApp()?.DiscoverSyncDevices || getWailsApp()?.ListSyncDevices));
    group.classList.toggle('hidden', !entry.visible);
    openBtn.disabled = !entry.canOpen;
    statusEl.textContent = entry.status;
}

function openUxSyncSettings() {
    const overlay = document.getElementById('ux-sync-settings-modal-overlay');
    if (!overlay) return;
    overlay.classList.remove('hidden');
    switchUxSyncSettingsTab('devices');
    void refreshUxSyncPeers();
}

function closeUxSyncSettings() {
    document.getElementById('ux-sync-settings-modal-overlay')?.classList.add('hidden');
}

function switchUxSyncSettingsTab(tabName: string): void {
    document.querySelectorAll<HTMLButtonElement>('.ux-sync-settings-tab[data-ux-sync-tab]').forEach(tab => {
        const active = tab.dataset.uxSyncTab === tabName;
        tab.classList.toggle('active', active);
        tab.setAttribute('aria-selected', active ? 'true' : 'false');
    });
    document.querySelectorAll<HTMLElement>('.ux-sync-settings-panel[data-ux-sync-panel]').forEach(panel => {
        panel.classList.toggle('hidden', panel.dataset.uxSyncPanel !== tabName);
    });
    if (tabName === 'sync') {
        refreshUxSyncTransferPeers();
    }
}

function refreshUxSyncTransferPeers(): void {
    const select = document.getElementById('ux-sync-transfer-peer-select') as HTMLSelectElement | null;
    if (!select) return;
    const previous = select.value;
    select.innerHTML = '';

    const empty = document.createElement('option');
    empty.value = '';
    empty.textContent = uxSyncPeers.length > 0 || uxSyncDevices.length > 0 ? '同期元を選択' : '検出済み端末なし';
    select.appendChild(empty);

    for (const peer of uxSyncPeers) {
        const baseUrl = syncPeerPairingBaseUrl(peer);
        if (!baseUrl) {
            continue;
        }
        const option = document.createElement('option');
        option.value = baseUrl;
        option.textContent = `${peer.displayName}${peer.paired ? ' (ペアリング済み)' : ''} - ${baseUrl}`;
        select.appendChild(option);
    }

    if (previous && Array.from(select.options).some(option => option.value === previous)) {
        select.value = previous;
    } else if (select.options.length === 2) {
        select.selectedIndex = 1;
    }
    updateUxSyncTransferActions();
}

function selectedUxSyncTransferBaseUrl(): string {
    const select = document.getElementById('ux-sync-transfer-peer-select') as HTMLSelectElement | null;
    return select?.value || '';
}

function updateUxSyncTransferActions(preserveStatus = false): void {
    const pullOneBtn = document.getElementById('ux-sync-pull-one-btn') as HTMLButtonElement | null;
    const pullAllBtn = document.getElementById('ux-sync-pull-all-btn') as HTMLButtonElement | null;
    const pushOneBtn = document.getElementById('ux-sync-push-one-btn') as HTMLButtonElement | null;
    const pushAllBtn = document.getElementById('ux-sync-push-all-btn') as HTMLButtonElement | null;
    const statusEl = document.getElementById('ux-sync-transfer-status');
    const baseUrl = selectedUxSyncTransferBaseUrl();
    const pullState = syncPullActionState(Boolean(getWailsApp()?.PullSyncLibraryAssets), baseUrl);
    const pushState = syncPushActionState(Boolean(getWailsApp()?.PushSyncLibraryAssets), baseUrl);
    if (pullOneBtn) pullOneBtn.disabled = !pullState.canPull;
    if (pullAllBtn) pullAllBtn.disabled = !pullState.canPull;
    if (pushOneBtn) pushOneBtn.disabled = !pushState.canPush;
    if (pushAllBtn) pushAllBtn.disabled = !pushState.canPush;
    if (statusEl && !preserveStatus && statusEl.textContent !== '取得中...' && statusEl.textContent !== '転送中...') {
        statusEl.textContent = pullState.canPull || pushState.canPush ? '待機中' : pullState.status;
    }
}

function selectedUxSyncEncodingMode(): string {
    const select = document.getElementById('ux-sync-transfer-encoding-select') as HTMLSelectElement | null;
    return select?.value || 'original';
}

function bindUxSyncTransferProgress(): void {
    if (uxSyncTransferProgressUnsubscribe || !window.runtime?.EventsOn) {
        return;
    }
    uxSyncTransferProgressUnsubscribe = window.runtime.EventsOn('ux-sync-transfer-progress', (payload: unknown) => {
        const progress = normaliseSyncTransferProgress(payload);
        if (!progress) {
            return;
        }
        const statusEl = document.getElementById('ux-sync-transfer-status');
        const logEl = document.getElementById('ux-sync-transfer-log');
        const summary = formatSyncTransferProgressSummary(progress);
        if (statusEl) {
            statusEl.textContent = summary;
        }
        if (logEl) {
            const percent = progress.bytesTotal > 0
                ? `\n${Math.min(100, Math.round((progress.bytesDone / progress.bytesTotal) * 100))}% (${formatSyncTransferBytes(progress.bytesDone)} / ${formatSyncTransferBytes(progress.bytesTotal)})`
                : '';
            logEl.textContent = `${summary}${percent}`;
        }
    });
}

function formatSyncTransferBytes(bytes: number): string {
    if (!Number.isFinite(bytes) || bytes <= 0) {
        return '0 B';
    }
    const mib = bytes / 1024 / 1024;
    if (mib >= 1) {
        return `${(Math.round(mib * 10) / 10).toFixed(1)} MB`;
    }
    const kib = bytes / 1024;
    return `${(Math.round(kib * 10) / 10).toFixed(1)} KB`;
}

async function runUxSyncPull(limit: number): Promise<void> {
    const baseUrl = selectedUxSyncTransferBaseUrl();
    const pullOneBtn = document.getElementById('ux-sync-pull-one-btn') as HTMLButtonElement | null;
    const pullAllBtn = document.getElementById('ux-sync-pull-all-btn') as HTMLButtonElement | null;
    const pushOneBtn = document.getElementById('ux-sync-push-one-btn') as HTMLButtonElement | null;
    const pushAllBtn = document.getElementById('ux-sync-push-all-btn') as HTMLButtonElement | null;
    const statusEl = document.getElementById('ux-sync-transfer-status');
    const logEl = document.getElementById('ux-sync-transfer-log');
    const state = syncPullActionState(Boolean(getWailsApp()?.PullSyncLibraryAssets), baseUrl);
    if (!state.canPull) {
        if (statusEl) statusEl.textContent = state.status;
        return;
    }

    if (pullOneBtn) pullOneBtn.disabled = true;
    if (pullAllBtn) pullAllBtn.disabled = true;
    if (pushOneBtn) pushOneBtn.disabled = true;
    if (pushAllBtn) pushAllBtn.disabled = true;
    if (statusEl) statusEl.textContent = '取得中...';
    if (logEl) logEl.textContent = '';
    bindUxSyncTransferProgress();

    try {
        const result = normaliseSyncPullResult(await musicApi.pullSyncLibraryAssets(baseUrl, limit));
        if (!result) {
            throw new Error('音源取得応答が不正です。');
        }
        if (statusEl) statusEl.textContent = formatSyncPullResultSummary(result);
        if (logEl) {
            const latestPath = result.importedPaths[0] || '';
            const errors = result.errors.length > 0 ? `\n${result.errors.join('\n')}` : '';
            logEl.textContent = latestPath ? `${latestPath}${errors}` : errors;
        }
        if (result.downloaded > 0) {
            await musicApi.loadLibrary();
            await renderCurrentView();
        }
    } catch (e) {
        if (statusEl) statusEl.textContent = `取得に失敗しました: ${(e as Error)?.message || String(e)}`;
    } finally {
        updateUxSyncTransferActions(true);
    }
}

async function runUxSyncPush(limit: number): Promise<void> {
    const baseUrl = selectedUxSyncTransferBaseUrl();
    const pullOneBtn = document.getElementById('ux-sync-pull-one-btn') as HTMLButtonElement | null;
    const pullAllBtn = document.getElementById('ux-sync-pull-all-btn') as HTMLButtonElement | null;
    const pushOneBtn = document.getElementById('ux-sync-push-one-btn') as HTMLButtonElement | null;
    const pushAllBtn = document.getElementById('ux-sync-push-all-btn') as HTMLButtonElement | null;
    const statusEl = document.getElementById('ux-sync-transfer-status');
    const logEl = document.getElementById('ux-sync-transfer-log');
    const state = syncPushActionState(Boolean(getWailsApp()?.PushSyncLibraryAssets), baseUrl);
    if (!state.canPush) {
        if (statusEl) statusEl.textContent = state.status;
        return;
    }

    if (pullOneBtn) pullOneBtn.disabled = true;
    if (pullAllBtn) pullAllBtn.disabled = true;
    if (pushOneBtn) pushOneBtn.disabled = true;
    if (pushAllBtn) pushAllBtn.disabled = true;
    if (statusEl) statusEl.textContent = '転送中...';
    if (logEl) logEl.textContent = '';
    bindUxSyncTransferProgress();

    try {
        const result = normaliseSyncPushResult(await musicApi.pushSyncLibraryAssets(baseUrl, limit, {
            encodingMode: selectedUxSyncEncodingMode(),
        }));
        if (!result) {
            throw new Error('音源転送応答が不正です。');
        }
        if (statusEl) statusEl.textContent = formatSyncPushResultSummary(result);
        if (logEl) {
            const latestPath = result.importedPaths[0] || '';
            const errors = result.errors.length > 0 ? `\n${result.errors.join('\n')}` : '';
            logEl.textContent = latestPath ? `${latestPath}${errors}` : errors;
        }
    } catch (e) {
        if (statusEl) statusEl.textContent = `転送に失敗しました: ${(e as Error)?.message || String(e)}`;
    } finally {
        updateUxSyncTransferActions(true);
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
        stateLabel.textContent = syncPeerConnectionLabel(peer);
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

        item.append(name, endpoint, roles, hosts, renderUxSyncPairingActions(peer));
        listEl.appendChild(item);
    }
}

function renderUxSyncPairingActions(peer: SyncPeer): HTMLElement {
    const actions = document.createElement('div');
    actions.className = 'ux-sync-pairing-actions';
    renderUxSyncPairingStart(actions, peer);
    return actions;
}

function renderUxSyncPairingStart(actions: HTMLElement, peer: SyncPeer): void {
    actions.innerHTML = '';
    const baseUrl = syncPeerPairingBaseUrl(peer);
    const status = document.createElement('p');
    status.className = 'ux-sync-pairing-status';
    status.setAttribute('aria-live', 'polite');

    const connectBtn = document.createElement('button');
    connectBtn.type = 'button';
    connectBtn.className = 'settings-button ux-sync-connect-btn';
    connectBtn.textContent = peer.paired ? '接続済み' : '接続';
    connectBtn.disabled = peer.paired || !baseUrl;

    if (peer.paired) {
        status.textContent = 'この端末とはペアリング済みです。';
    } else if (!baseUrl) {
        status.textContent = '到達URL未確認';
    }

    connectBtn.addEventListener('click', async () => {
        connectBtn.disabled = true;
        connectBtn.textContent = '開始中...';
        status.textContent = '6桁コードを取得しています。';
        try {
            const started = normaliseSyncPairingStart(await musicApi.startSyncPairing(baseUrl));
            if (!started) {
                throw new Error('ペアリング開始応答が不正です。');
            }
            renderUxSyncPairingConfirm(actions, peer, started);
        } catch (e) {
            connectBtn.disabled = false;
            connectBtn.textContent = '接続';
            status.textContent = `接続開始に失敗しました: ${(e as Error)?.message || String(e)}`;
        }
    });

    actions.append(connectBtn, status);
}

function renderUxSyncPairingConfirm(actions: HTMLElement, peer: SyncPeer, started: SyncPairingStart): void {
    actions.innerHTML = '';

    const code = document.createElement('div');
    code.className = 'ux-sync-pairing-code';
    code.textContent = started.code;

    const status = document.createElement('p');
    status.className = 'ux-sync-pairing-status';
    status.setAttribute('aria-live', 'polite');
    status.textContent = `${started.remoteDisplayName || peer.displayName} のコードを確認してください。`;

    const confirmBtn = document.createElement('button');
    confirmBtn.type = 'button';
    confirmBtn.className = 'settings-button ux-sync-confirm-btn';
    confirmBtn.textContent = '確定';

    const cancelBtn = document.createElement('button');
    cancelBtn.type = 'button';
    cancelBtn.className = 'settings-button secondary ux-sync-cancel-btn';
    cancelBtn.textContent = 'キャンセル';

    confirmBtn.addEventListener('click', async () => {
        confirmBtn.disabled = true;
        cancelBtn.disabled = true;
        confirmBtn.textContent = '確定中...';
        status.textContent = 'ペアリングを確定しています。';
        try {
            const confirmed = normaliseSyncPairingConfirm(
                await musicApi.confirmSyncPairing(started.baseUrl, started.sessionId, started.code, started.remoteDeviceId)
            );
            if (!confirmed?.tokenSaved) {
                throw new Error('トークン保存に失敗しました。');
            }
            actions.innerHTML = '';
            const done = document.createElement('p');
            done.className = 'ux-sync-pairing-status ux-sync-pairing-done';
            done.textContent = `${confirmed.remoteDisplayName || started.remoteDisplayName || peer.displayName} とペアリングしました。`;
            actions.appendChild(done);
            void refreshUxSyncPeers();
        } catch (e) {
            confirmBtn.disabled = false;
            cancelBtn.disabled = false;
            confirmBtn.textContent = '確定';
            status.textContent = `ペアリングに失敗しました: ${(e as Error)?.message || String(e)}`;
        }
    });

    cancelBtn.addEventListener('click', () => {
        renderUxSyncPairingStart(actions, peer);
    });

    const buttonRow = document.createElement('div');
    buttonRow.className = 'ux-sync-pairing-button-row';
    buttonRow.append(confirmBtn, cancelBtn);

    actions.append(code, status, buttonRow);
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
        updateUxSyncSettingsEntry();
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

    const syncSettingsOpenBtn = document.getElementById('ux-sync-settings-open-btn');
    if (syncSettingsOpenBtn && !syncSettingsOpenBtn.dataset.listenerAttached) {
        syncSettingsOpenBtn.addEventListener('click', openUxSyncSettings);
        syncSettingsOpenBtn.dataset.listenerAttached = 'true';
    }

    const syncSettingsCloseBtn = document.getElementById('ux-sync-settings-close-btn');
    if (syncSettingsCloseBtn && !syncSettingsCloseBtn.dataset.listenerAttached) {
        syncSettingsCloseBtn.addEventListener('click', closeUxSyncSettings);
        syncSettingsCloseBtn.dataset.listenerAttached = 'true';
    }

    document.querySelectorAll<HTMLButtonElement>('.ux-sync-settings-tab[data-ux-sync-tab]').forEach(tab => {
        if (tab.dataset.listenerAttached) return;
        tab.addEventListener('click', () => {
            if (tab.dataset.uxSyncTab) {
                switchUxSyncSettingsTab(tab.dataset.uxSyncTab);
            }
        });
        tab.dataset.listenerAttached = 'true';
    });

    const syncTransferSelect = document.getElementById('ux-sync-transfer-peer-select');
    if (syncTransferSelect && !syncTransferSelect.dataset.listenerAttached) {
        syncTransferSelect.addEventListener('change', () => {
            updateUxSyncTransferActions();
        });
        syncTransferSelect.dataset.listenerAttached = 'true';
    }

    const syncTransferEncodingSelect = document.getElementById('ux-sync-transfer-encoding-select') as HTMLSelectElement | null;
    if (syncTransferEncodingSelect && !syncTransferEncodingSelect.dataset.optionsInitialised) {
        syncTransferEncodingSelect.innerHTML = '';
        for (const option of syncTransferEncodingOptions()) {
            const el = document.createElement('option');
            el.value = option.value;
            el.textContent = option.label;
            syncTransferEncodingSelect.appendChild(el);
        }
        syncTransferEncodingSelect.dataset.optionsInitialised = 'true';
    }

    const syncPullOneBtn = document.getElementById('ux-sync-pull-one-btn');
    if (syncPullOneBtn && !syncPullOneBtn.dataset.listenerAttached) {
        syncPullOneBtn.addEventListener('click', () => {
            void runUxSyncPull(1);
        });
        syncPullOneBtn.dataset.listenerAttached = 'true';
    }

    const syncPullAllBtn = document.getElementById('ux-sync-pull-all-btn');
    if (syncPullAllBtn && !syncPullAllBtn.dataset.listenerAttached) {
        syncPullAllBtn.addEventListener('click', () => {
            void runUxSyncPull(0);
        });
        syncPullAllBtn.dataset.listenerAttached = 'true';
    }

    const syncPushOneBtn = document.getElementById('ux-sync-push-one-btn');
    if (syncPushOneBtn && !syncPushOneBtn.dataset.listenerAttached) {
        syncPushOneBtn.addEventListener('click', () => {
            void runUxSyncPush(1);
        });
        syncPushOneBtn.dataset.listenerAttached = 'true';
    }

    const syncPushAllBtn = document.getElementById('ux-sync-push-all-btn');
    if (syncPushAllBtn && !syncPushAllBtn.dataset.listenerAttached) {
        syncPushAllBtn.addEventListener('click', () => {
            void runUxSyncPush(0);
        });
        syncPushAllBtn.dataset.listenerAttached = 'true';
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
