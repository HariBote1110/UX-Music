let elements = {};
let ipc = {};

// 初期化
export function initPlaylists(uiElements, ipcRenderer) {
    elements = uiElements;
    ipc = ipcRenderer;
    elements.createPlaylistBtn.addEventListener('click', handleCreatePlaylist);
}

// 新規プレイリスト作成ボタンの処理
function handleCreatePlaylist() {
    elements.showModal({
        title: '新規プレイリスト',
        placeholder: 'プレイリスト名',
        onOk: async (name) => {
            const result = await ipc.invoke('create-playlist', name);
            if (result.success) {
                // 成功したら、メインプロセスにプレイリスト一覧の再取得を要求
                ipc.send('request-all-playlists');
            } else {
                alert(`エラー: ${result.message}`);
            }
        }
    });
}