// src/renderer/js/edit-metadata.js
import { state } from './state.js';
import { resolveArtworkPath } from './ui/utils.js';
import { renderCurrentView } from './ui-manager.js';
import { showNotification, hideNotification } from './ui/notification.js';
const electronAPI = window.electronAPI;

let currentEditingSong = null;
let newArtworkBuffer = null; // 新しいアートワークのバイナリデータ
let removeArtwork = false; // アートワーク削除フラグ

// モーダル要素への参照
const elements = {
    overlay: document.getElementById('edit-metadata-modal-overlay'),
    modal: document.getElementById('edit-metadata-modal'),
    artworkPreview: document.getElementById('edit-artwork-preview'),
    artworkInput: document.getElementById('edit-artwork-input'),
    changeArtworkBtn: document.getElementById('edit-artwork-change-btn'),
    removeArtworkBtn: document.getElementById('edit-artwork-remove-btn'),
    artworkError: document.getElementById('edit-artwork-error'),
    titleInput: document.getElementById('edit-title'),
    artistInput: document.getElementById('edit-artist'),
    albumInput: document.getElementById('edit-album'),
    genreInput: document.getElementById('edit-genre'),
    cancelBtn: document.getElementById('edit-metadata-cancel-btn'),
    saveBtn: document.getElementById('edit-metadata-save-btn'),
};

// イベントリスナーの初期化（一度だけ実行）
function initEditMetadataListeners() {
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
    // リスナーが設定されたことを示すフラグ
    initEditMetadataListeners.initialized = true;
}

/**
 * メタデータ編集モーダルを表示する
 * @param {object} song - 編集対象の曲オブジェクト
 */
export function showEditMetadataModal(song) {
    if (!initEditMetadataListeners.initialized) {
        initEditMetadataListeners();
    }

    currentEditingSong = song;
    newArtworkBuffer = null;
    removeArtwork = false;
    elements.artworkError.classList.add('hidden');
    elements.artworkInput.value = ''; // ファイル選択をリセット

    // 現在の情報をフォームに設定
    elements.titleInput.value = song.title || '';
    elements.artistInput.value = song.artist || '';
    elements.albumInput.value = song.album || '';
    elements.genreInput.value = song.genre || '';

    // アートワークプレビューを設定
    const album = state.albums.get(song.albumKey);
    const artwork = song.artwork || (album ? album.artwork : null);
    elements.artworkPreview.src = resolveArtworkPath(artwork, false);

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
    elements.artworkError.classList.add('hidden');
    elements.artworkPreview.src = './assets/default_artwork.png'; // デフォルト画像に戻す
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
        const album = state.albums.get(currentEditingSong.albumKey);
        const artwork = currentEditingSong.artwork || (album ? album.artwork : null);
        elements.artworkPreview.src = resolveArtworkPath(artwork, false);
        return;
    }

    // FileReaderでファイルを読み込み、プレビュー表示とバッファ保持
    const reader = new FileReader();
    reader.onload = (e) => {
        elements.artworkPreview.src = e.target.result; // プレビュー更新
        newArtworkBuffer = Buffer.from(e.target.result.split(',')[1], 'base64'); // Base64部分をBufferに
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
    elements.artworkPreview.src = './assets/default_artwork.png';
    newArtworkBuffer = null;
    removeArtwork = true;
    elements.artworkInput.value = ''; // ファイル選択をリセット
    elements.artworkError.classList.add('hidden');
}

/**
 * 保存ボタンが押されたときの処理
 */
async function handleSave() {
    if (!currentEditingSong) return;

    // 新しいタグ情報を収集
    const newTags = {
        title: elements.titleInput.value.trim(),
        artist: elements.artistInput.value.trim(),
        album: elements.albumInput.value.trim(),
        genre: elements.genreInput.value.trim(),
        // アートワーク情報を含める (削除または新しいバッファ)
        image: removeArtwork ? null : (newArtworkBuffer ? { mime: 'image/png', type: { id: 3, name: 'front cover' }, description: 'Cover', imageBuffer: newArtworkBuffer } : undefined), // undefinedなら変更なし
    };

    // 保存ボタンを一時的に無効化など（任意）
    elements.saveBtn.disabled = true;
    elements.saveBtn.textContent = '保存中...';

    try {
        const result = await electronAPI.invoke('edit-metadata', {
            filePath: currentEditingSong.path,
            newTags: newTags
        });

        if (result.success && result.updatedSong) {
            // state.library の情報を更新
            const index = state.library.findIndex(s => s.id === currentEditingSong.id);
            if (index > -1) {
                // 更新された曲オブジェクトで置き換える (メインプロセスから返された情報を使う)
                state.library[index] = { ...state.library[index], ...result.updatedSong };

                // state.albums も更新する必要がある
                // 簡単のため、ライブラリ全体からアルバムとアーティストを再グループ化
                electronAPI.send('request-initial-library'); // ライブラリ再読み込みを要求
            }

            hideEditMetadataModal();
            showNotification(`「${result.updatedSong.title}」の情報が更新されました。`);
            hideNotification(3000);
            renderCurrentView(); // UIを再描画して変更を反映
        } else {
            showNotification(`エラー: ${result.message || 'メタデータの保存に失敗しました。'}`);
            hideNotification(5000);
        }
    } catch (error) {
        console.error('メタデータ保存IPCエラー:', error);
        showNotification('エラー: メタデータの保存中に問題が発生しました。');
        hideNotification(5000);
    } finally {
        // 保存ボタンの状態を元に戻す
        elements.saveBtn.disabled = false;
        elements.saveBtn.textContent = '保存';
    }
}