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
            // ★★★ 修正箇所 ★★★
            // if (result.success) {
            //     // このIPC通信は不要なため削除します。
            //     // メインプロセス側で作成成功時に'playlists-updated'が送信されるためです。
            //     ipc.send('request-all-playlists');
            // } else {
            //     alert(`エラー: ${result.message}`);
            // }
            // エラー時のみ通知するように修正
            if (!result.success) {
                alert(`エラー: ${result.message}`);
            }
        }
    });
}