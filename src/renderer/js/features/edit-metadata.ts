// src/renderer/js/edit-metadata.js
import { state } from '../core/state.js';
import { resolveArtworkPath } from '../ui/utils.js';
import { rebuildLibraryIndexes } from '../core/library-model.js';
import { renderCurrentView } from '../ui/ui-manager.js';
import { showNotification, hideNotification } from '../ui/notification.js';
import { DEFAULT_ARTWORK_URL } from '../constants/default-artwork.js';
const electronAPI = window.electronAPI;

let currentEditingSong: Record<string, unknown> | null = null;
let newArtworkBuffer: unknown = null;
let removeArtwork = false;

const elements = {
    overlay: document.getElementById('edit-metadata-modal-overlay'),
    modal: document.getElementById('edit-metadata-modal'),
    artworkPreview: document.getElementById('edit-artwork-preview') as HTMLImageElement | null,
    artworkInput: document.getElementById('edit-artwork-input') as HTMLInputElement | null,
    changeArtworkBtn: document.getElementById('edit-artwork-change-btn'),
    removeArtworkBtn: document.getElementById('edit-artwork-remove-btn'),
    artworkError: document.getElementById('edit-artwork-error'),
    titleInput: document.getElementById('edit-title') as HTMLInputElement | null,
    artistInput: document.getElementById('edit-artist') as HTMLInputElement | null,
    albumInput: document.getElementById('edit-album') as HTMLInputElement | null,
    genreInput: document.getElementById('edit-genre') as HTMLInputElement | null,
    cancelBtn: document.getElementById('edit-metadata-cancel-btn'),
    saveBtn: document.getElementById('edit-metadata-save-btn') as HTMLButtonElement | null,
};

// イベントリスナーの初期化（一度だけ実行）
function initEditMetadataListeners(): void {
    elements.cancelBtn.addEventListener('click', hideEditMetadataModal);
    elements.saveBtn.addEventListener('click', handleSave);
    elements.changeArtworkBtn.addEventListener('click', () => elements.artworkInput.click());
    elements.removeArtworkBtn.addEventListener('click', handleRemoveArtwork);
    elements.artworkInput.addEventListener('change', handleArtworkChange);
    elements.overlay.addEventListener('click', (e) => {
        if (e.target === elements.overlay) {
            hideEditMetadataModal();
        }
    });
    initEditMetadataListeners._initialized = true;
}
initEditMetadataListeners._initialized = false;

export function showEditMetadataModal(song: Record<string, unknown>) {
    if (!initEditMetadataListeners._initialized) {
        initEditMetadataListeners();
    }

    currentEditingSong = song;
    newArtworkBuffer = null;
    removeArtwork = false;
    elements.artworkError.classList.add('hidden');
    elements.artworkInput.value = ''; // ファイル選択をリセット

    if (elements.titleInput) elements.titleInput.value = (song.title as string) || '';
    if (elements.artistInput) elements.artistInput.value = (song.artist as string) || '';
    if (elements.albumInput) elements.albumInput.value = (song.album as string) || '';
    if (elements.genreInput) elements.genreInput.value = (song.genre as string) || '';

    const album = state.albums.get(song.albumKey as string) as Record<string, unknown> | undefined;
    const artwork = song.artwork || (album ? album.artwork : null);
    if (elements.artworkPreview) elements.artworkPreview.src = resolveArtworkPath(artwork, false);

    elements.overlay.classList.remove('hidden');
}

/**
 * メタデータ編集モーダルを非表示にする
 */
function hideEditMetadataModal() {
    elements.overlay.classList.add('hidden');
    currentEditingSong = null;
    newArtworkBuffer = null;
    removeArtwork = false;
    // エラーメッセージなどをクリア
    elements.artworkError?.classList.add('hidden');
    if (elements.artworkPreview) elements.artworkPreview.src = DEFAULT_ARTWORK_URL;
}

/**
 * アートワークファイルが選択されたときの処理
 * @param {Event} event - input要素のchangeイベント
 */
async function handleArtworkChange(event) {
    const file = event.target.files[0];
    elements.artworkError.classList.add('hidden');
    if (!file) return;

    // ファイルサイズのチェック (例: 5MB以下)
    const maxSize = 5 * 1024 * 1024;
    if (file.size > maxSize) {
        elements.artworkError.textContent = 'ファイルサイズは5MB以下にしてください。';
        elements.artworkError.classList.remove('hidden');
        newArtworkBuffer = null;
        removeArtwork = false;
        // プレビューを元の画像に戻す（もし曲に元々アートワークがあれば）
        const album2 = state.albums.get(currentEditingSong.albumKey as string) as Record<string, unknown> | undefined;
        const artwork2 = currentEditingSong.artwork || (album2 ? album2.artwork : null);
        if (elements.artworkPreview) elements.artworkPreview.src = resolveArtworkPath(artwork2, false);
        return;
    }

    // FileReaderでファイルを読み込み、プレビュー表示とバッファ保持
    const reader = new FileReader();
    reader.onload = (e) => {
        const resultStr = e.target!.result as string;
        if (elements.artworkPreview) elements.artworkPreview.src = resultStr;
        newArtworkBuffer = Buffer.from(resultStr.split(',')[1], 'base64');
        removeArtwork = false; // 新しい画像が選択されたら削除フラグは解除
    };
    reader.onerror = (e) => {
        elements.artworkError.textContent = 'ファイルの読み込みに失敗しました。';
        elements.artworkError.classList.remove('hidden');
        newArtworkBuffer = null;
    };
    reader.readAsDataURL(file); // Data URLとして読み込む
}

/**
 * アートワーク削除ボタンが押されたときの処理
 */
function handleRemoveArtwork() {
    if (elements.artworkPreview) elements.artworkPreview.src = DEFAULT_ARTWORK_URL;
    newArtworkBuffer = null;
    removeArtwork = true;
    if (elements.artworkInput) elements.artworkInput.value = '';
    elements.artworkError?.classList.add('hidden');
}

/**
 * 保存ボタンが押されたときの処理
 */
async function handleSave() {
    if (!currentEditingSong) return;

    // 新しいタグ情報を収集
    const newTags = {
        title: elements.titleInput?.value.trim(),
        artist: elements.artistInput?.value.trim(),
        album: elements.albumInput?.value.trim(),
        genre: elements.genreInput?.value.trim(),
        // アートワーク情報を含める (削除または新しいバッファ)
        image: removeArtwork ? null : (newArtworkBuffer ? { mime: 'image/png', type: { id: 3, name: 'front cover' }, description: 'Cover', imageBuffer: newArtworkBuffer } : undefined), // undefinedなら変更なし
    };

    // 保存ボタンを一時的に無効化など（任意）
    if (elements.saveBtn) { elements.saveBtn.disabled = true; elements.saveBtn.textContent = '保存中...'; }

    try {
        const result = await electronAPI.invoke('edit-metadata', {
            filePath: currentEditingSong.path,
            newTags: newTags
        }) as Record<string, unknown>;

        if (result.success && result.updatedSong) {
            const updatedSong = result.updatedSong as Record<string, unknown>;
            const index = state.library.findIndex(s => s.id === currentEditingSong!.id);
            if (index > -1) {
                state.library[index] = { ...state.library[index], ...updatedSong };
                rebuildLibraryIndexes();
                electronAPI.send('request-initial-library');
            }

            hideEditMetadataModal();
            showNotification(`「${updatedSong.title}」の情報が更新されました。`, 3000);
            renderCurrentView();
        } else {
            showNotification(`エラー: ${(result.message as string) || 'メタデータの保存に失敗しました。'}`, 5000);
        }
    } catch (error) {
        console.error('メタデータ保存IPCエラー:', error);
        showNotification('エラー: メタデータの保存中に問題が発生しました。');
        hideNotification(5000);
    } finally {
        if (elements.saveBtn) { elements.saveBtn.disabled = false; elements.saveBtn.textContent = '保存'; }
    }
}
