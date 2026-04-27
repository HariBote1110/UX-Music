// src/renderer/js/cd-ripper.js

import { escapeHtml } from '../ui/utils.js';
import { DEFAULT_ARTWORK_URL } from '../constants/default-artwork.js';

const electronAPI = window.electronAPI;

let currentTracks = [];
let isRipping = false;

/** CD 取り込み画面の HTML（旧 components/cd-ripper.html の本体） */
export function getCdRipViewHtml() {
    return `<div class="cd-rip-container">
    <div class="cd-rip-header">
        <div class="cd-artwork-container" id="cd-artwork-container" title="クリックしてジャケット画像を変更">
            <img id="cd-artwork-preview" src="./assets/default_artwork.png" class="cd-artwork-img" alt="Album art">
            <input type="file" id="cd-artwork-file-input" accept="image/*" style="display: none;">
        </div>

        <div class="cd-album-info">
            <h2 id="cd-album-title" class="cd-album-title">Unknown Album</h2>
            <div id="cd-album-artist" class="cd-album-artist">Unknown Artist</div>
            <div id="cd-status-message" class="cd-status-message">CDドライブを確認中...</div>
        </div>

        <div class="cd-controls-pane">
            <div class="cd-settings-group">
                <div class="cd-setting-row">
                    <span>形式</span>
                    <select id="cd-format-select" class="cd-select">
                        <option value="flac" selected>FLAC</option>
                        <option value="alac">ALAC (m4a)</option>
                        <option value="wav">WAV</option>
                        <option value="aac">AAC (m4a)</option>
                        <option value="mp3">MP3</option>
                    </select>
                </div>
                <div id="cd-bitrate-container" class="cd-setting-row" style="display: none;">
                    <span>品質</span>
                    <select id="cd-bitrate-select" class="cd-select">
                        <option value="320k" selected>320 kbps</option>
                        <option value="256k">256 kbps</option>
                        <option value="192k">192 kbps</option>
                        <option value="128k">128 kbps</option>
                    </select>
                </div>
            </div>

            <div class="cd-buttons-row">
                <button id="cd-metadata-btn" type="button" class="action-button" disabled>検索</button>
                <button id="cd-scan-btn" type="button" class="action-button">再読込</button>
            </div>
            <button id="cd-import-btn" type="button" class="action-button primary" style="width: 100%;" disabled>CDを取り込む</button>
        </div>
    </div>

    <div class="cd-tracks-list-container">
        <table class="cd-track-table">
            <thead>
                <tr>
                    <th style="width: 50px;">#</th>
                    <th>タイトル</th>
                    <th>アーティスト</th>
                    <th style="width: 80px; text-align: right;">時間</th>
                    <th style="width: 100px; text-align: center;">状態</th>
                </tr>
            </thead>
            <tbody id="cd-tracks-tbody">
            </tbody>
        </table>
    </div>

    <div id="cd-progress-area" class="cd-progress-area hidden">
        <div style="display: flex; justify-content: space-between; margin-bottom: 5px; font-size: 0.9rem;">
            <span id="cd-progress-text">準備中...</span>
            <span id="cd-progress-percent">0%</span>
        </div>
        <div class="cd-progress-bar-bg">
            <div id="cd-progress-bar" class="cd-progress-bar-fill"></div>
        </div>
    </div>

    <div id="cd-metadata-modal" class="modal-overlay hidden">
        <div class="modal-content">
            <h3 style="margin: 0 0 16px 0; color: #fff;">アルバム情報を設定</h3>

            <div style="background: #222; border: 1px solid #444; border-radius: 6px; padding: 12px; margin-bottom: 14px;">
                <p style="color: #aaa; font-size: 0.8em; margin: 0 0 8px 0; text-transform: uppercase; letter-spacing: 0.05em;">手入力</p>
                <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-bottom: 8px;">
                    <input type="text" id="cd-manual-album" placeholder="アルバム名"
                           style="padding: 8px; border-radius: 4px; border: 1px solid #555; background: #333; color: white; outline: none;">
                    <input type="text" id="cd-manual-artist" placeholder="アーティスト名"
                           style="padding: 8px; border-radius: 4px; border: 1px solid #555; background: #333; color: white; outline: none;">
                </div>
                <input type="number" id="cd-manual-year" placeholder="年 (例: 2024)" min="1900" max="2099"
                       style="width: 100%; box-sizing: border-box; padding: 8px; border-radius: 4px; border: 1px solid #555; background: #333; color: white; outline: none; margin-bottom: 8px;">
                <button id="cd-manual-apply-btn" type="button" class="action-button" style="width: 100%; padding: 7px;">適用</button>
            </div>

            <div style="border-top: 1px solid #333; padding-top: 14px;">
                <p style="color: #aaa; font-size: 0.8em; margin: 0 0 8px 0; text-transform: uppercase; letter-spacing: 0.05em;">MusicBrainz 検索</p>
                <div style="display: flex; gap: 10px; margin-bottom: 10px;">
                    <input type="text" id="cd-search-input" placeholder="アーティスト名 / アルバム名"
                           style="flex: 1; padding: 8px 10px; border-radius: 4px; border: 1px solid #555; background: #333; color: white; outline: none;">
                    <button id="cd-search-submit-btn" type="button" class="action-button">検索</button>
                </div>
                <div style="overflow-y: auto; border: 1px solid #444; border-radius: 4px; background: #1a1a1a; margin-bottom: 12px; min-height: 120px; max-height: 200px;">
                    <ul id="cd-candidate-list" style="list-style: none; padding: 0; margin: 0;"></ul>
                </div>
            </div>

            <div style="display: flex; justify-content: space-between; align-items: center;">
                <button id="cd-ai-metadata-btn" type="button" class="action-button" style="width: auto; padding: 8px 16px; background: #2a4a7a;">🤖 AIで生成</button>
                <button id="cd-search-cancel-btn" type="button" class="action-button" style="width: auto; padding: 8px 24px;">閉じる</button>
            </div>
        </div>
    </div>

    <div id="cd-ai-modal" class="modal-overlay hidden">
        <div class="modal-content" style="max-width: 560px;">
            <h3 style="margin: 0 0 16px 0; color: #fff;">🤖 AIでメタデータを生成</h3>
            <p style="color: #aaa; font-size: 0.9em; margin: 0 0 12px 0;">ジャケット画像とともに以下のプロンプトを任意のAI（ChatGPT・Claude等）に送り、返答のJSONをペーストしてください。</p>
            <div style="display: flex; gap: 8px; margin-bottom: 12px;">
                <button id="cd-ai-copy-prompt-btn" type="button" class="action-button" style="width: auto; padding: 8px 14px;">プロンプトをコピー</button>
                <span id="cd-ai-copy-status" style="color: #4caf50; font-size: 0.85em; align-self: center;"></span>
            </div>
            <textarea id="cd-ai-json-input" placeholder='AIの返答JSONをここにペースト...' rows="8"
                style="width: 100%; box-sizing: border-box; padding: 10px; border-radius: 4px; border: 1px solid #555; background: #1a1a1a; color: white; font-family: monospace; font-size: 0.85em; resize: vertical; outline: none; margin-bottom: 12px;"></textarea>
            <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-bottom: 12px;">
                <input type="text" id="cd-ai-album-override" placeholder="アルバム名（空欄=AI任せ）"
                       style="padding: 8px; border-radius: 4px; border: 1px solid #555; background: #333; color: white; outline: none;">
                <input type="text" id="cd-ai-artist-override" placeholder="アーティスト名（空欄=AI任せ）"
                       style="padding: 8px; border-radius: 4px; border: 1px solid #555; background: #333; color: white; outline: none;">
            </div>
            <div style="display: flex; justify-content: flex-end; gap: 10px;">
                <button id="cd-ai-cancel-btn" type="button" class="action-button" style="width: auto; padding: 8px 24px;">キャンセル</button>
                <button id="cd-ai-apply-btn" type="button" class="action-button primary" style="width: auto; padding: 8px 24px;">適用</button>
            </div>
        </div>
    </div>
</div>`;
}

/**
 * @param {HTMLElement} container
 */
export async function renderCdRipView(container) {
    container.innerHTML = `<div id="cd-rip-view" class="cd-rip-view-inner">${getCdRipViewHtml()}</div>`;
    await startCDRipView();
}

export async function startCDRipView() {
    const scanBtn = document.getElementById('cd-scan-btn');
    const importBtn = document.getElementById('cd-import-btn');
    const metadataBtn = document.getElementById('cd-metadata-btn');
    const formatSelect = document.getElementById('cd-format-select');

    if (scanBtn) scanBtn.onclick = scanCD;
    if (importBtn) importBtn.onclick = startImport;
    if (metadataBtn) metadataBtn.onclick = openMetadataSearch;

    if (formatSelect) {
        // 保存済みの形式を復元
        try {
            const settings: any = await electronAPI.invoke('get-settings');
            const saved = settings?.cdRipFormat;
            if (saved) (formatSelect as HTMLSelectElement).value = saved;
        } catch (_) {}

        formatSelect.onchange = () => {
            toggleBitrateSelect();
            electronAPI.send('save-settings', { cdRipFormat: (formatSelect as HTMLSelectElement).value });
        };
        toggleBitrateSelect();
    }

    // モーダルイベント
    document.getElementById('cd-search-submit-btn').onclick = executeTextSearch;
    document.getElementById('cd-search-cancel-btn').onclick = closeMetadataModal;
    document.getElementById('cd-search-input').onkeydown = (e) => {
        if (e.key === 'Enter') executeTextSearch();
    };
    document.getElementById('cd-ai-metadata-btn').onclick = openAiModal;
    document.getElementById('cd-ai-cancel-btn').onclick = closeAiModal;
    document.getElementById('cd-ai-copy-prompt-btn').onclick = copyAiPrompt;
    document.getElementById('cd-ai-apply-btn').onclick = applyAiJson;
    document.getElementById('cd-manual-apply-btn').onclick = applyManualFields;

    // アートワーク画像選択
    const artworkContainer = document.getElementById('cd-artwork-container');
    const artworkFileInput = document.getElementById('cd-artwork-file-input') as HTMLInputElement;
    if (artworkContainer && artworkFileInput) {
        artworkContainer.onclick = () => artworkFileInput.click();
        artworkFileInput.onchange = () => {
            const file = artworkFileInput.files?.[0];
            if (!file) return;
            const reader = new FileReader();
            reader.onload = (e) => {
                const dataUrl = e.target?.result as string;
                const preview = document.getElementById('cd-artwork-preview') as HTMLImageElement;
                if (preview) preview.src = dataUrl;
                // 全トラックにアートワークを設定
                currentTracks.forEach((t: any) => { t.artwork = dataUrl; });
            };
            reader.readAsDataURL(file);
        };
    }

    // 初回スキャン
    await scanCD();

    electronAPI.on('rip-progress', onProgress);
}

export function stopCDRipView() {
    (electronAPI as unknown as { removeAllListeners: (ch: string) => void }).removeAllListeners('rip-progress');
    currentTracks = [];
}

function toggleBitrateSelect() {
    const format = (document.getElementById('cd-format-select') as HTMLInputElement | null)?.value;
    const bitrateContainer = document.getElementById('cd-bitrate-container') as HTMLElement | null;
    // 非可逆圧縮形式のみビットレート選択を表示
    if (format === 'aac' || format === 'mp3') {
        if (bitrateContainer) bitrateContainer.style.display = 'flex';
    } else {
        if (bitrateContainer) bitrateContainer.style.display = 'none';
    }
}

async function scanCD() {
    if (isRipping) return;
    const statusMsg = document.getElementById('cd-status-message');
    const importBtn = document.getElementById('cd-import-btn');
    const metadataBtn = document.getElementById('cd-metadata-btn');
    const albumTitle = document.getElementById('cd-album-title');
    const albumArtist = document.getElementById('cd-album-artist');
    const artworkImg = document.getElementById('cd-artwork-preview');

    // リセット
    if (albumTitle) albumTitle.textContent = 'Unknown Album';
    if (albumArtist) albumArtist.textContent = 'Unknown Artist';
    if (artworkImg) (artworkImg as HTMLImageElement).src = DEFAULT_ARTWORK_URL;

    if (statusMsg) statusMsg.textContent = 'ドライブをスキャン中...';
    if (importBtn) (importBtn as HTMLButtonElement).disabled = true;
    if (metadataBtn) (metadataBtn as HTMLButtonElement).disabled = true;

    try {
        const result = await electronAPI.invoke('cd-scan') as Record<string, unknown>;
        if (!result.success) {
            if (statusMsg) statusMsg.textContent = `エラー: ${result.message}`;
            return;
        }
        currentTracks = result.tracks as typeof currentTracks;
        if (currentTracks.length === 0) {
            if (statusMsg) statusMsg.textContent = 'CDが見つかりません。';
            return;
        }

        if (statusMsg) statusMsg.textContent = `${currentTracks.length} トラック検出。メタデータを検索中...`;
        renderTracks(currentTracks);

        if (importBtn) (importBtn as HTMLButtonElement).disabled = false;
        if (metadataBtn) (metadataBtn as HTMLButtonElement).disabled = false;

        // 自動メタデータ検索
        try {
            const searchResult = await electronAPI.invoke('cd-search-toc', currentTracks) as Record<string, unknown>;
            const searchReleases = searchResult.releases as Record<string, unknown>[] | undefined;
            if (searchResult.success && searchReleases && searchReleases.length > 0) {
                const releases = searchReleases;
                if (releases.length === 1) {
                    if (statusMsg) statusMsg.textContent = 'メタデータが見つかりました。適用中...';
                    await applyMetadata(releases[0].id);
                } else {
                    if (statusMsg) statusMsg.textContent = '複数の候補が見つかりました。選択してください。';
                    showMetadataModal();
                    renderCandidateList(releases);
                }
            } else {
                if (statusMsg) statusMsg.textContent = 'メタデータが見つかりませんでした。手動で検索してください。';
            }
        } catch (searchError) {
            console.error('Auto metadata search failed:', searchError);
            if (statusMsg) statusMsg.textContent = 'メタデータ検索中にエラーが発生しました。';
        }

    } catch (error) {
        console.error(error);
    }
}

// ▼▼▼ メタデータ検索機能 (変更なし) ▼▼▼
function showMetadataModal() {
    const modal = document.getElementById('cd-metadata-modal');
    modal.classList.remove('hidden');
    modal.style.display = 'flex';

    // 手入力フィールドを現在の値で初期化
    const firstTrack = currentTracks[0];
    (document.getElementById('cd-manual-album') as HTMLInputElement).value = firstTrack?.album ?? '';
    (document.getElementById('cd-manual-artist') as HTMLInputElement).value = firstTrack?.artist ?? '';
    (document.getElementById('cd-manual-year') as HTMLInputElement).value = '';

    const searchInput = document.getElementById('cd-search-input') as HTMLInputElement;
    searchInput.value = '';
    searchInput.focus();
}

async function openMetadataSearch() {
    showMetadataModal();
    const list = document.getElementById('cd-candidate-list');
    list.innerHTML = '<li style="padding: 10px; color: #aaa;">自動検索中...</li>';
    try {
        const result = await electronAPI.invoke('cd-search-toc', currentTracks) as Record<string, unknown>;
        const tocReleases = result.releases as Record<string, unknown>[] | undefined;
        if (result.success && tocReleases?.length) {
            renderCandidateList(tocReleases);
        } else {
            list.innerHTML = '<li style="padding: 10px; color: #aaa;">自動検索で見つかりませんでした。キーワードで検索してください。</li>';
        }
    } catch (e) {
        list.innerHTML = `<li style="padding: 10px; color: red;">エラー: ${(e as Error).message}</li>`;
    }
}

async function executeTextSearch() {
    const query = (document.getElementById('cd-search-input') as HTMLInputElement | null)?.value ?? '';
    const list = document.getElementById('cd-candidate-list');
    if (!query) return;
    list.innerHTML = '<li style="padding: 10px; color: #aaa;">検索中...</li>';
    try {
        const result = await electronAPI.invoke('cd-search-text', query) as Record<string, unknown>;
        const textReleases = result.releases as Record<string, unknown>[] | undefined;
        if (result.success && textReleases?.length) {
            renderCandidateList(textReleases);
        } else {
            list.innerHTML = '<li style="padding: 10px; color: #aaa;">見つかりませんでした。</li>';
        }
    } catch (e) {
        list.innerHTML = `<li style="padding: 10px; color: red;">エラー: ${(e as Error).message}</li>`;
    }
}

function renderCandidateList(releases) {
    const list = document.getElementById('cd-candidate-list');
    list.innerHTML = '';
    releases.forEach(release => {
        const li = document.createElement('li');
        li.style.padding = '10px';
        li.style.borderBottom = '1px solid #444';
        li.style.cursor = 'pointer';
        li.style.display = 'flex';
        li.style.justifyContent = 'space-between';
        li.onmouseover = () => li.style.background = '#444';
        li.onmouseout = () => li.style.background = 'transparent';

        const artist = escapeHtml(release['artist-credit']?.[0]?.name || 'Unknown');
        const title = escapeHtml(release.title);
        const date = escapeHtml(release.date || '----');

        li.innerHTML = `<div><div style="font-weight: bold; color: white;">${title}</div><div style="font-size: 0.9em; color: #ccc;">${artist}</div></div><div style="font-size: 0.9em; color: #aaa; text-align: right;"><div>${date}</div></div>`;
        li.onclick = () => applyMetadata(release.id);
        list.appendChild(li);
    });
}

async function applyMetadata(releaseId) {
    const list = document.getElementById('cd-candidate-list');
    if (list) list.innerHTML = '<li style="padding: 10px; color: #aaa;">詳細情報を取得中...</li>';
    try {
        const result = await electronAPI.invoke('cd-apply-metadata', { tracks: currentTracks, releaseId: releaseId }) as Record<string, unknown>;
        if (result.success) {
            currentTracks = result.tracks as typeof currentTracks;
            renderTracks(currentTracks);
            document.getElementById('cd-album-title').textContent = result.album as string;
            document.getElementById('cd-album-artist').textContent = result.artist as string;
            document.getElementById('cd-status-message').textContent = 'メタデータを適用しました。';

            const artworkImg = document.getElementById('cd-artwork-preview') as HTMLImageElement | null;
            if (artworkImg) {
                artworkImg.src = (result.artwork as string | null) ? (result.artwork as string) : DEFAULT_ARTWORK_URL;
            }
            closeMetadataModal();
        } else {
            alert('情報の適用に失敗しました: ' + (result as Record<string, unknown>).message);
            closeMetadataModal();
        }
    } catch (e) {
        alert('エラーが発生しました: ' + (e as Error).message);
    }
}

function closeMetadataModal() {
    const modal = document.getElementById('cd-metadata-modal');
    modal.style.display = 'none';
    modal.classList.add('hidden');
}

// ▲▲▲ メタデータ検索機能ここまで ▲▲▲

function renderTracks(tracks) {
    const tbody = document.getElementById('cd-tracks-tbody');
    if (!tbody) return;
    tbody.innerHTML = tracks.map(track => `
        <tr style="border-bottom: 1px solid #333;">
            <td style="padding: 8px;">${escapeHtml(track.number)}</td>
            <td style="padding: 8px;"><input type="text" class="cd-track-input" data-id="${escapeHtml(track.number)}" data-field="title" value="${escapeHtml(track.title)}" style="background: transparent; border: none; color: white; width: 100%; border-bottom: 1px solid #555;"></td>
            <td style="padding: 8px;"><input type="text" class="cd-track-input" data-id="${escapeHtml(track.number)}" data-field="artist" value="${escapeHtml(track.artist)}" style="background: transparent; border: none; color: white; width: 100%; border-bottom: 1px solid #555;"></td>
            <td style="padding: 8px;">${escapeHtml(track.duration || getDurationStr(track.sectors))}</td>
            <td style="padding: 8px;" id="status-cell-${escapeHtml(track.number)}">待機中</td>
        </tr>
    `).join('');
    tbody.querySelectorAll('.cd-track-input').forEach(input => {
        input.addEventListener('change', (e) => {
            const target = e.target as HTMLInputElement;
            const id = parseInt(target.dataset.id);
            const field = target.dataset.field;
            const track = currentTracks.find(t => t.number === id);
            if (track) track[field] = target.value;
        });
    });
}

function getDurationStr(sectors) {
    if (!sectors) return '--:--';
    const totalSeconds = Math.floor(sectors / 75);
    const min = Math.floor(totalSeconds / 60);
    const sec = totalSeconds % 60;
    return `${min}:${String(sec).padStart(2, '0')}`;
}

async function startImport() {
    if (isRipping || currentTracks.length === 0) return;

    isRipping = true;
    const importBtn = document.getElementById('cd-import-btn') as HTMLButtonElement | null;
    const scanBtn = document.getElementById('cd-scan-btn') as HTMLButtonElement | null;
    const metadataBtn = document.getElementById('cd-metadata-btn') as HTMLButtonElement | null;
    const progressArea = document.getElementById('cd-progress-area');
    const progressText = document.getElementById('cd-progress-text');
    const progressBar = document.getElementById('cd-progress-bar');

    const format = (document.getElementById('cd-format-select') as HTMLSelectElement).value;
    const bitrate = (document.getElementById('cd-bitrate-select') as HTMLSelectElement).value;
    const artworkImg = document.getElementById('cd-artwork-preview') as HTMLImageElement;
    const artworkSrc = (artworkImg && !artworkImg.src.includes('default_artwork')) ? artworkImg.src : null;
    const artworkData = artworkSrc?.startsWith('data:') ? artworkSrc : null;
    const artworkUrl = (!artworkData && artworkSrc) ? artworkSrc : null;

    if (importBtn) importBtn.disabled = true;
    if (scanBtn) scanBtn.disabled = true;
    if (metadataBtn) metadataBtn.disabled = true;
    if (progressArea) progressArea.classList.remove('hidden');

    try {
        const result = await electronAPI.invoke('cd-start-rip', {
            tracksToRip: currentTracks,
            options: { format, bitrate, artworkUrl, artworkData }
        }) as Record<string, unknown>;

        isRipping = false;
        if (importBtn) importBtn.disabled = false;
        if (scanBtn) scanBtn.disabled = false;
        if (metadataBtn) metadataBtn.disabled = false;
        if (progressText) progressText.textContent = 'インポート完了！ライブラリに追加しました。';
        if (progressBar) progressBar.style.width = '100%';

        setTimeout(() => {
            alert(`${result?.count ?? currentTracks.length} 曲のインポートが完了しました。`);
            if (progressArea) progressArea.classList.add('hidden');
            if (progressBar) progressBar.style.width = '0%';
        }, 1000);
    } catch (e) {
        isRipping = false;
        if (importBtn) importBtn.disabled = false;
        if (scanBtn) scanBtn.disabled = false;
        if (metadataBtn) metadataBtn.disabled = false;
        alert(`取り込みに失敗しました: ${(e as Error).message}`);
        if (progressArea) progressArea.classList.add('hidden');
    }
}

function onProgress(data) {
    // preload.js は event を除いて args のみを渡すので、data が最初の引数
    if (!data) return;
    const { status, trackNumber: track, percent, error } = data;

    const statusCell = document.getElementById(`status-cell-${track}`);
    const progressText = document.getElementById('cd-progress-text');
    const progressBar = document.getElementById('cd-progress-bar');

    if (status === 'ripping') {
        const pct = Math.floor(percent ?? 0);
        if (statusCell) statusCell.textContent = '吸出し中...';
        if (progressText) progressText.textContent = `Track ${track} を吸出し中... (${pct}%)`;
        if (progressBar) progressBar.style.width = `${pct}%`;
    } else if (status === 'encoding') {
        if (statusCell) statusCell.textContent = '変換中...';
        if (progressText) progressText.textContent = `Track ${track} を変換中...`;
        if (progressBar) progressBar.style.width = '100%';
    } else if (status === 'completed') {
        if (statusCell) {
            statusCell.textContent = '完了';
            statusCell.style.color = '#1db954';
        }
    } else if (status === 'error') {
        if (statusCell) {
            statusCell.textContent = 'エラー';
            statusCell.style.color = '#ff5555';
        }
        console.error(`Track ${track} error:`, error);
    }
}

// ─── 手入力 適用 ──────────────────────────────────────────────────────────────

function applyManualFields() {
    const album  = (document.getElementById('cd-manual-album') as HTMLInputElement).value.trim();
    const artist = (document.getElementById('cd-manual-artist') as HTMLInputElement).value.trim();
    const yearVal = (document.getElementById('cd-manual-year') as HTMLInputElement).value.trim();

    if (!album && !artist) {
        alert('アルバム名またはアーティスト名を入力してください。');
        return;
    }

    currentTracks.forEach(t => {
        if (album)  t.album  = album;
        if (artist) t.artist = artist;
    });
    renderTracks(currentTracks);

    if (album)  { const el = document.getElementById('cd-album-title');  if (el) el.textContent = album; }
    if (artist) { const el = document.getElementById('cd-album-artist'); if (el) el.textContent = artist; }

    const statusMsg = document.getElementById('cd-status-message');
    if (statusMsg) statusMsg.textContent = '手入力のメタデータを適用しました。';

    closeMetadataModal();
}

// ─── AI メタデータ生成 ────────────────────────────────────────────────────────

function buildAiPrompt(): string {
    const trackCount = currentTracks.length;
    const schema = JSON.stringify({
        artist: 'アーティスト名',
        album: 'アルバム名',
        year: 2024,
        tracks: Array.from({ length: trackCount || 1 }, (_, i) => ({
            number: i + 1,
            title: '曲名',
            artist: 'アーティスト名（アルバムアーティストと同じ場合も明記）'
        }))
    }, null, 2);

    return `あなたはCDのメタデータ抽出の専門家です。
添付した画像（CDジャケット・帯・ブックレット等）から以下のJSONスキーマに従いメタデータを抽出してください。

ルール:
- tracksは必ず${trackCount}件にしてください
- 不明な値は空文字にしてください（nullや省略は不可）
- コードブロックなし・JSONのみを返してください
- 日本語の情報があれば日本語を優先してください

スキーマ:
${schema}`;
}

function openAiModal() {
    const modal = document.getElementById('cd-ai-modal');
    const textarea = document.getElementById('cd-ai-json-input') as HTMLTextAreaElement;
    modal.classList.remove('hidden');
    modal.style.display = 'flex';
    textarea.value = '';
    const status = document.getElementById('cd-ai-copy-status');
    if (status) status.textContent = '';
}

function closeAiModal() {
    const modal = document.getElementById('cd-ai-modal');
    modal.style.display = 'none';
    modal.classList.add('hidden');
}

async function copyAiPrompt() {
    const prompt = buildAiPrompt();
    try {
        await navigator.clipboard.writeText(prompt);
        const status = document.getElementById('cd-ai-copy-status');
        if (status) {
            status.textContent = 'コピーしました！';
            setTimeout(() => { status.textContent = ''; }, 2500);
        }
    } catch {
        alert('クリップボードへのコピーに失敗しました。');
    }
}

function applyAiJson() {
    const textarea = document.getElementById('cd-ai-json-input') as HTMLTextAreaElement;
    const raw = textarea.value.trim();
    if (!raw) {
        alert('JSONをペーストしてください。');
        return;
    }

    let parsed: { artist?: string; album?: string; year?: number; tracks?: { number: number; title: string; artist: string }[] };
    try {
        // コードブロック除去
        const cleaned = raw.replace(/^```[a-z]*\n?/i, '').replace(/\n?```$/,'').trim();
        parsed = JSON.parse(cleaned);
    } catch {
        alert('JSONの解析に失敗しました。AIの返答をそのままペーストしてください。');
        return;
    }

    if (!parsed.tracks || !Array.isArray(parsed.tracks)) {
        alert('tracks フィールドが見つかりません。');
        return;
    }

    // オーバーライドフィールドが入力されていればそちらを優先
    const albumOverride  = (document.getElementById('cd-ai-album-override') as HTMLInputElement).value.trim();
    const artistOverride = (document.getElementById('cd-ai-artist-override') as HTMLInputElement).value.trim();
    const finalAlbum  = albumOverride  || parsed.album  || '';
    const finalArtist = artistOverride || parsed.artist || '';

    // currentTracks に反映
    parsed.tracks.forEach(t => {
        const target = currentTracks.find(c => c.number === t.number);
        if (target) {
            if (t.title)    target.title  = t.title;
            if (t.artist)   target.artist = artistOverride || t.artist;
            if (finalAlbum) target.album  = finalAlbum;
        }
    });

    renderTracks(currentTracks);

    if (finalAlbum)  { const el = document.getElementById('cd-album-title');  if (el) el.textContent = finalAlbum; }
    if (finalArtist) { const el = document.getElementById('cd-album-artist'); if (el) el.textContent = finalArtist; }
    const statusMsg = document.getElementById('cd-status-message');
    if (statusMsg) statusMsg.textContent = 'AIメタデータを適用しました。';

    closeAiModal();
    closeMetadataModal();
}
