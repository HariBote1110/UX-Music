// @ts-nocheck
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
        <div class="cd-artwork-container">
            <img id="cd-artwork-preview" src="./assets/default_artwork.png" class="cd-artwork-img" alt="Album art">
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
                        <option value="flac">FLAC</option>
                        <option value="alac" selected>ALAC (m4a)</option>
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
            <h3 style="margin: 0 0 20px 0; color: #fff;">アルバム情報を検索</h3>
            <div style="display: flex; gap: 10px; margin-bottom: 15px;">
                <input type="text" id="cd-search-input" placeholder="アーティスト名 / アルバム名"
                       style="flex: 1; padding: 10px; border-radius: 4px; border: 1px solid #555; background: #333; color: white; outline: none;">
                <button id="cd-search-submit-btn" type="button" class="action-button">検索</button>
            </div>
            <div style="flex: 1; overflow-y: auto; border: 1px solid #444; border-radius: 4px; background: #1a1a1a; margin-bottom: 15px; min-height: 200px;">
                <ul id="cd-candidate-list" style="list-style: none; padding: 0; margin: 0;">
                </ul>
            </div>
            <div style="text-align: right;">
                <button id="cd-search-cancel-btn" type="button" class="action-button" style="width: auto; padding: 8px 24px;">キャンセル</button>
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
        formatSelect.onchange = toggleBitrateSelect;
        toggleBitrateSelect(); // 初期状態セット
    }

    // モーダルイベント
    document.getElementById('cd-search-submit-btn').onclick = executeTextSearch;
    document.getElementById('cd-search-cancel-btn').onclick = closeMetadataModal;
    document.getElementById('cd-search-input').onkeydown = (e) => {
        if (e.key === 'Enter') executeTextSearch();
    };

    // 初回スキャン
    await scanCD();

    electronAPI.on('rip-progress', onProgress);
    electronAPI.on('rip-complete', onComplete);
}

export function stopCDRipView() {
    electronAPI.removeAllListeners('rip-progress');
    electronAPI.removeAllListeners('rip-complete');
    currentTracks = [];
}

function toggleBitrateSelect() {
    const format = document.getElementById('cd-format-select').value;
    const bitrateContainer = document.getElementById('cd-bitrate-container');
    // 非可逆圧縮形式のみビットレート選択を表示
    if (format === 'aac' || format === 'mp3') {
        bitrateContainer.style.display = 'flex';
    } else {
        bitrateContainer.style.display = 'none';
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
    if (artworkImg) artworkImg.src = DEFAULT_ARTWORK_URL;

    if (statusMsg) statusMsg.textContent = 'ドライブをスキャン中...';
    if (importBtn) importBtn.disabled = true;
    if (metadataBtn) metadataBtn.disabled = true;

    try {
        const result = await electronAPI.invoke('cd-scan');
        if (!result.success) {
            if (statusMsg) statusMsg.textContent = `エラー: ${result.message}`;
            return;
        }
        currentTracks = result.tracks;
        if (currentTracks.length === 0) {
            if (statusMsg) statusMsg.textContent = 'CDが見つかりません。';
            return;
        }

        if (statusMsg) statusMsg.textContent = `${currentTracks.length} トラック検出。メタデータを検索中...`;
        renderTracks(currentTracks);

        if (importBtn) importBtn.disabled = false;
        if (metadataBtn) metadataBtn.disabled = false;

        // 自動メタデータ検索
        try {
            const searchResult = await electronAPI.invoke('cd-search-toc', currentTracks);
            if (searchResult.success && searchResult.releases && searchResult.releases.length > 0) {
                const releases = searchResult.releases;
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
    const input = document.getElementById('cd-search-input');
    modal.classList.remove('hidden');
    modal.style.display = 'flex';
    input.value = '';
    input.focus();
}

async function openMetadataSearch() {
    showMetadataModal();
    const list = document.getElementById('cd-candidate-list');
    list.innerHTML = '<li style="padding: 10px; color: #aaa;">自動検索中...</li>';
    try {
        const result = await electronAPI.invoke('cd-search-toc', currentTracks);
        if (result.success && result.releases.length > 0) {
            renderCandidateList(result.releases);
        } else {
            list.innerHTML = '<li style="padding: 10px; color: #aaa;">自動検索で見つかりませんでした。キーワードで検索してください。</li>';
        }
    } catch (e) {
        list.innerHTML = `<li style="padding: 10px; color: red;">エラー: ${e.message}</li>`;
    }
}

async function executeTextSearch() {
    const query = document.getElementById('cd-search-input').value;
    const list = document.getElementById('cd-candidate-list');
    if (!query) return;
    list.innerHTML = '<li style="padding: 10px; color: #aaa;">検索中...</li>';
    try {
        const result = await electronAPI.invoke('cd-search-text', query);
        if (result.success && result.releases.length > 0) {
            renderCandidateList(result.releases);
        } else {
            list.innerHTML = '<li style="padding: 10px; color: #aaa;">見つかりませんでした。</li>';
        }
    } catch (e) {
        list.innerHTML = `<li style="padding: 10px; color: red;">エラー: ${e.message}</li>`;
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
        const result = await electronAPI.invoke('cd-apply-metadata', { tracks: currentTracks, releaseId: releaseId });
        if (result.success) {
            currentTracks = result.tracks;
            renderTracks(currentTracks);
            document.getElementById('cd-album-title').textContent = result.album;
            document.getElementById('cd-album-artist').textContent = result.artist;
            document.getElementById('cd-status-message').textContent = 'メタデータを適用しました。';

            const artworkImg = document.getElementById('cd-artwork-preview');
            if (artworkImg) {
                artworkImg.src = result.artwork ? result.artwork : DEFAULT_ARTWORK_URL;
            }
            closeMetadataModal();
        } else {
            alert('情報の適用に失敗しました: ' + result.message);
            closeMetadataModal();
        }
    } catch (e) {
        alert('エラーが発生しました: ' + e.message);
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
            const id = parseInt(e.target.dataset.id);
            const field = e.target.dataset.field;
            const track = currentTracks.find(t => t.number === id);
            if (track) track[field] = e.target.value;
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

function startImport() {
    if (isRipping || currentTracks.length === 0) return;

    isRipping = true;
    const importBtn = document.getElementById('cd-import-btn');
    const scanBtn = document.getElementById('cd-scan-btn');
    const metadataBtn = document.getElementById('cd-metadata-btn');
    const progressArea = document.getElementById('cd-progress-area');

    // 設定値の取得
    const format = document.getElementById('cd-format-select').value;
    const bitrate = document.getElementById('cd-bitrate-select').value;
    // アートワークURLの取得 (img要素からsrcを取得)
    const artworkImg = document.getElementById('cd-artwork-preview');
    const artworkUrl = (artworkImg && !artworkImg.src.includes('default_artwork')) ? artworkImg.src : null;

    if (importBtn) importBtn.disabled = true;
    if (scanBtn) scanBtn.disabled = true;
    if (metadataBtn) metadataBtn.disabled = true;
    if (progressArea) progressArea.classList.remove('hidden');

    // 設定とアートワーク情報を送信
    electronAPI.send('cd-start-rip', {
        tracksToRip: currentTracks,
        options: {
            format: format, // flac, wav, alac, aac, mp3
            bitrate: bitrate, // 320k, 256k...
            artworkUrl: artworkUrl
        }
    });
}

function onProgress(data) {
    // preload.js は event を除いて args のみを渡すので、data が最初の引数
    if (!data) return;
    const { status, track, percent, error } = data;

    const statusCell = document.getElementById(`status-cell-${track}`);
    const progressText = document.getElementById('cd-progress-text');
    const progressBar = document.getElementById('cd-progress-bar');

    if (status === 'ripping') {
        if (statusCell) statusCell.textContent = '吸出し中...';
        if (progressText) progressText.textContent = `Track ${track} を吸出し中... (${percent}%)`;
        if (progressBar) progressBar.style.width = `${percent}%`;
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

function onComplete(data) {
    if (!data) return;
    isRipping = false;

    const importBtn = document.getElementById('cd-import-btn');
    const scanBtn = document.getElementById('cd-scan-btn');
    const metadataBtn = document.getElementById('cd-metadata-btn');
    const progressText = document.getElementById('cd-progress-text');
    const progressBar = document.getElementById('cd-progress-bar');
    const progressArea = document.getElementById('cd-progress-area');

    if (importBtn) importBtn.disabled = false;
    if (scanBtn) scanBtn.disabled = false;
    if (metadataBtn) metadataBtn.disabled = false;
    if (progressText) progressText.textContent = 'インポート完了！';
    if (progressBar) progressBar.style.width = '100%';

    setTimeout(() => {
        alert(`${data.count} 曲のインポートが完了しました。`);
        if (progressArea) progressArea.classList.add('hidden');
        if (progressBar) progressBar.style.width = '0%';
    }, 1000);
}
