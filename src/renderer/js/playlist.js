import { elements } from './state.js';
import { showModal } from './modal.js';
const { ipcRenderer } = require('electron');

export function initPlaylists() {
    elements.createPlaylistBtn.addEventListener('click', handleCreatePlaylist);
}

function handleCreatePlaylist() {
    showModal({
        title: '新規プレイリスト',
        placeholder: 'プレイリスト名',
        onOk: async (name) => {
            const result = await ipcRenderer.invoke('create-playlist', name);
            if (!result.success) {
                alert(`エラー: ${result.message}`);
            }
        }
    });
}