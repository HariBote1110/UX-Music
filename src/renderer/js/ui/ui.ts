import { state, elements } from '../core/state.js';
import { initQueueSidebarMtpHandlers } from './ui-manager.js';
import { setupSongListScroller, createListHeader, initListHeaderResizing } from './list-renderer.js';
export { updateNowPlayingView } from './now-playing.js';
const electronAPI = window.electronAPI;

/**
 * 再生バーの高さに基づいて、全リスト共通の余白（--footer-height）を更新する
 * :root に設定することで、VirtualScroller や CSS ::after が参照可能になる
 */
export function updateListSpacer() {
    const playbackBar = document.querySelector('.playback-bar');
    if (playbackBar) {
        const barRect = playbackBar.getBoundingClientRect();
        if (barRect.height > 0) {
            // 再生バーがビューポートの下半分にある（通常の浮遊配置）場合のみ
            // ビューポート下端からの重なり量をスペーサーに反映する。
            // MusicCenter テーマ時は上部ツールバーになるため重なりは発生しない。
            const isAtBottom = barRect.top > window.innerHeight / 2;
            if (isAtBottom) {
                const overlapHeight = window.innerHeight - barRect.top;
                const spacerHeight = Math.max(0, Math.ceil(overlapHeight + 8));
                document.documentElement.style.setProperty('--footer-height', `${spacerHeight}px`);
            } else {
                document.documentElement.style.removeProperty('--footer-height');
            }
        }
    } else {
        document.documentElement.style.removeProperty('--footer-height');
    }
}

let listSpacerResizeRaf = null;
function scheduleListSpacerUpdate() {
    if (listSpacerResizeRaf != null) return;
    listSpacerResizeRaf = requestAnimationFrame(() => {
        listSpacerResizeRaf = null;
        updateListSpacer();
    });
}

export function initUI() {
    // ウィンドウリサイズ時にスペーサーの高さを再計算（1 フレームに 1 回まで）
    window.addEventListener('resize', scheduleListSpacerUpdate);

    // 初回実行（レンダリング完了を見越して少し遅延させる）
    setTimeout(updateListSpacer, 100);

    // フルスクリーンオーバーレイ起動用の右クリックメニューを設定する
    void import('./now-playing.js').then(({ setupArtworkContextMenu }) => {
        setupArtworkContextMenu();
    });

    // --- MTP転送画面のボタン用イベントハンドラ（動的コンポーネント対応） ---
    document.addEventListener('click', (e) => {
        const target = (e.target as Element).closest('button');
        if (!target) return;

        // 「ディレクトリを見る」ボタン
        if (target.id === 'mtp-transfer-browse-btn') {
            console.log('[MTP Transfer] ディレクトリを見るボタンがクリックされました');

            if (!state.mtpStorages || state.mtpStorages.length === 0) {
                console.warn('[MTP Transfer] ストレージ情報がありません');
                return;
            }

            const storageId = (state.mtpStorages[0] as Record<string, unknown>).id;
            console.log('[MTP Transfer] storageId:', storageId);

            void import('../core/navigation.js').then(({ showView }) =>
                showView('mtp-browser-view', {
                    storageId: storageId,
                    initialPath: '/'
                })
            );
        }

        if (target.id === 'mtp-transfer-close-btn') {
            void import('../core/navigation.js').then(({ showView }) => {
                showView(state.activeListView || 'track-view');
            });
        }

        // 「>>」転送ボタン or 「すべて転送」ボタン
        if (target.id === 'mtp-transfer-start-btn' || target.id === 'mtp-transfer-all-btn') {
            console.log('[MTP Transfer] 転送ボタンがクリックされました');

            if (!state.mtpStorages || state.mtpStorages.length === 0) {
                console.warn('[MTP Transfer] ストレージ情報がありません');
                import('./notification.js').then(({ showNotification }) => {
                    showNotification('Walkmanのストレージ情報が見つかりません。', 3000);
                });
                return;
            }

            if (!state.pendingTransferSongs || state.pendingTransferSongs.length === 0) {
                console.warn('[MTP Transfer] 転送する曲がありません');
                import('./notification.js').then(({ showNotification }) => {
                    showNotification('転送する曲がありません。', 3000);
                });
                return;
            }

            const storageId = (state.mtpStorages[0] as Record<string, unknown>).id;
            const songCount = state.pendingTransferSongs.length;

            console.log(`[MTP Transfer] ${songCount}曲を転送開始...`);

            // アーティスト/アルバムでグループ化
            const groupedSongs = new Map();
            for (const song of state.pendingTransferSongs) {
                // アーティスト名とアルバム名を安全な文字列に変換
                const artist = (song.artist || 'Unknown Artist').replace(/[\\/:*?"<>|]/g, '_');
                const album = (song.album || 'Unknown Album').replace(/[\\/:*?"<>|]/g, '_');
                const destPath = `/Music/${artist}/${album}/`;

                if (!groupedSongs.has(destPath)) {
                    groupedSongs.set(destPath, []);
                }
                groupedSongs.get(destPath).push(song.path);
            }

            console.log(`[MTP Transfer] ${groupedSongs.size}個のディレクトリに分けて転送`);

            import('./notification.js').then(async ({ showNotification }) => {
                showNotification(`${songCount}曲の転送を開始します...`, false);

                // 転送リストを作成（ソースパスと転送先パスのペア）
                const transferList: { source: string; destination: string }[] = [];
                for (const [destination, sources] of groupedSongs) {
                    for (const sourcePath of sources) {
                        transferList.push({ source: sourcePath, destination });
                    }
                }

                try {
                    // 1回のIPC呼び出しで全ファイルを転送
                    const result = await electronAPI.invoke('mtp-upload-files-with-structure', {
                        storageId,
                        transferList
                    }) as Record<string, unknown>;

                    if (result.error) {
                        console.error('[MTP Transfer] 転送に失敗しました:', result.error);
                        showNotification(`転送に失敗しました: ${result.error}`, 4000);
                    } else {
                        const successCount = (result.successCount as number) || songCount;
                        const errorCount = (result.errorCount as number) || 0;

                        if (errorCount === 0) {
                            showNotification(`${successCount}曲の転送が完了しました。`, 4000);
                            state.pendingTransferSongs = [];
                        } else {
                            showNotification(`転送完了: ${successCount}曲成功, ${errorCount}曲失敗`, 4000);
                        }
                    }
                } catch (err) {
                    console.error('[MTP Transfer] 転送エラー:', err);
                    showNotification(`転送中にエラーが発生しました: ${(err as Error).message}`, 4000);
                }
            });
        }
    });

    initQueueSidebarMtpHandlers();
}

let currentSearchQuery = '';

export function updateSearchQuery(query) {
    const newQuery = query.toLowerCase().trim();

    // クエリに変更がなく、かつ既にトラックビューなら何もしない
    if (currentSearchQuery === newQuery && state.activeViewId === 'track-view') return;

    currentSearchQuery = newQuery;

    // 検索クエリがある場合、または現在トラックビューにいる場合は描画更新
    if (currentSearchQuery) {
        if (state.activeViewId !== 'track-view') {
            switchToTrackView();
        }
        renderTrackView();
    } else {
        // 検索ボックスが空になった場合
        if (state.activeViewId === 'track-view') {
            // 全曲リストに戻す（ヘッダー付きで再描画）
            renderTrackView();
        }
    }
}

function switchToTrackView() {
    state.activeViewId = 'track-view';
    state.currentDetailView = { type: null, identifier: null, data: null };

    document.querySelectorAll('.view-container').forEach(el => el.classList.add('hidden'));
    if (elements.mainContent) elements.mainContent.classList.remove('hidden');

    if (elements.navLinks) {
        elements.navLinks.forEach(l => l.classList.remove('active'));
        const trackLink = document.querySelector('.nav-link[data-view="track-view"]');
        if (trackLink) trackLink.classList.add('active');
    }
}

export function renderTrackView() {
    // 1. フィルタリング
    let displaySongs = state.library;
    if (currentSearchQuery) {
        displaySongs = state.library.filter(song => {
            const targetText = (
                (song.title || '') +
                (song.artist || '') +
                (song.album || '')
            ).toLowerCase();
            return targetText.includes(currentSearchQuery);
        });
    }

    // 2. メインコンテンツをクリア
    elements.mainContent.innerHTML = '';

    // 3. ビュー構造（ヘッダー等）を再構築
    const viewWrapper = document.createElement('div');
    viewWrapper.className = 'view-container';
    viewWrapper.style.display = 'flex';
    viewWrapper.style.flexDirection = 'column';
    viewWrapper.style.height = '100%';

    // タイトルヘッダー
    const titleText = currentSearchQuery ? `検索結果: "${currentSearchQuery}"` : '曲';
    viewWrapper.innerHTML = `<h1>${titleText}</h1>`;

    // 項目ヘッダー（タイトル・アーティスト・アルバム...）
    const listHeaderWrapper = document.createElement('div');
    listHeaderWrapper.innerHTML = createListHeader();
    viewWrapper.appendChild(listHeaderWrapper.firstElementChild);

    // リストコンテナ（スクロール領域）
    const listContainer = document.createElement('div');
    listContainer.className = 'track-list-container';
    listContainer.style.flex = '1';
    listContainer.style.overflowY = 'auto'; // スクロール可能にする
    viewWrapper.appendChild(listContainer);

    elements.mainContent.appendChild(viewWrapper);

    // 4. リストの中身を描画
    if (displaySongs.length === 0) {
        listContainer.innerHTML = '<div class="placeholder">検索結果が見つかりません</div>';
        updateListSpacer();
        return;
    }

    setupSongListScroller(listContainer, displaySongs, {
        contextView: 'track-view'
    });

    // 生成後に高さを更新
    updateListSpacer();

    // 列リサイズの初期化
    initListHeaderResizing(viewWrapper);
}
