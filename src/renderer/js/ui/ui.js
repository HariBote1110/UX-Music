import { state, elements } from '../core/state.js';
import { setupSongListScroller, createListHeader, initListHeaderResizing } from './list-renderer.js';
import { resolveArtworkPath, formatSongTitle, checkTextOverflow } from './utils.js';
import { setEqualizerColorFromArtwork } from '../features/player.js';
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
            // ビューポート下端から再生バー上端までの実距離をそのまま使用する。
            const overlapHeight = window.innerHeight - barRect.top;
            const spacerHeight = Math.max(0, Math.ceil(overlapHeight + 8));
            document.documentElement.style.setProperty('--footer-height', `${spacerHeight}px`);
        }
    } else {
        document.documentElement.style.removeProperty('--footer-height');
    }
}

export function initUI() {
    // ウィンドウリサイズ時にスペーサーの高さを再計算
    window.addEventListener('resize', updateListSpacer);

    // 初回実行（レンダリング完了を見越して少し遅延させる）
    setTimeout(updateListSpacer, 100);

    // --- MTP転送画面のボタン用イベントハンドラ（動的コンポーネント対応） ---
    document.addEventListener('click', (e) => {
        const target = e.target.closest('button');
        if (!target) return;

        // 「ディレクトリを見る」ボタン
        if (target.id === 'mtp-transfer-browse-btn') {
            console.log('[MTP Transfer] ディレクトリを見るボタンがクリックされました');

            if (!state.mtpStorages || state.mtpStorages.length === 0) {
                console.warn('[MTP Transfer] ストレージ情報がありません');
                return;
            }

            const storageId = state.mtpStorages[0].id;
            console.log('[MTP Transfer] storageId:', storageId);

            // 転送画面を閉じてMTPブラウザビューを表示
            const mtpTransferView = document.getElementById('mtp-transfer-view');
            if (mtpTransferView) {
                mtpTransferView.classList.add('hidden');
            }

            // navigation.jsからshowViewをインポートできないため、直接遷移処理
            import('../core/navigation.js').then(({ showView }) => {
                showView('mtp-browser-view', {
                    storageId: storageId,
                    initialPath: '/'
                });
            });
        }

        // 「閉じる」ボタン
        if (target.id === 'mtp-transfer-close-btn') {
            const mtpTransferView = document.getElementById('mtp-transfer-view');
            const mainContent = document.getElementById('main-content');
            if (mtpTransferView) mtpTransferView.classList.add('hidden');
            if (mainContent) mainContent.classList.remove('hidden');
        }

        // 「>>」転送ボタン or 「すべて転送」ボタン
        if (target.id === 'mtp-transfer-start-btn' || target.id === 'mtp-transfer-all-btn') {
            console.log('[MTP Transfer] 転送ボタンがクリックされました');

            if (!state.mtpStorages || state.mtpStorages.length === 0) {
                console.warn('[MTP Transfer] ストレージ情報がありません');
                import('./notification.js').then(({ showNotification, hideNotification }) => {
                    showNotification('Walkmanのストレージ情報が見つかりません。');
                    hideNotification(3000);
                });
                return;
            }

            if (!state.pendingTransferSongs || state.pendingTransferSongs.length === 0) {
                console.warn('[MTP Transfer] 転送する曲がありません');
                import('./notification.js').then(({ showNotification, hideNotification }) => {
                    showNotification('転送する曲がありません。');
                    hideNotification(3000);
                });
                return;
            }

            const storageId = state.mtpStorages[0].id;
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

            import('./notification.js').then(async ({ showNotification, hideNotification }) => {
                showNotification(`${songCount}曲の転送を開始します...`);

                // 転送リストを作成（ソースパスと転送先パスのペア）
                const transferList = [];
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
                    });

                    if (result.error) {
                        console.error('[MTP Transfer] 転送に失敗しました:', result.error);
                        showNotification(`転送に失敗しました: ${result.error}`);
                    } else {
                        const successCount = result.successCount || songCount;
                        const errorCount = result.errorCount || 0;

                        if (errorCount === 0) {
                            showNotification(`${successCount}曲の転送が完了しました。`);
                            state.pendingTransferSongs = [];
                        } else {
                            showNotification(`転送完了: ${successCount}曲成功, ${errorCount}曲失敗`);
                        }
                    }
                } catch (err) {
                    console.error('[MTP Transfer] 転送エラー:', err);
                    showNotification(`転送中にエラーが発生しました: ${err.message}`);
                }

                hideNotification(4000);
            });
        }
    });
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

function getYoutubeVideoId(url) {
    if (typeof url !== 'string') return null;
    const regExp = /(?:youtube\.com\/(?:[^\/]+\/.+\/|(?:v|e(?:mbed)?)\/|.*[?&]v=)|youtu\.be\/)([^"&?\/ ]{11})/;
    const match = url.match(regExp);
    return match ? match[1] : null;
}

function buildArtworkCandidates(artwork) {
    const candidates = [];
    const appendUnique = (value) => {
        if (typeof value !== 'string' || value.trim() === '') return;
        if (!candidates.includes(value)) {
            candidates.push(value);
        }
    };

    if (artwork && typeof artwork === 'object' && artwork.full && artwork.thumbnail) {
        appendUnique(resolveArtworkPath(artwork, false));
        appendUnique(resolveArtworkPath(artwork, true));
    } else {
        appendUnique(resolveArtworkPath(artwork, false));

        // Legacy artwork filename fallback: try thumbnail naming convention if available.
        if (typeof artwork === 'string' && /\.webp$/i.test(artwork) && !/_thumb\.webp$/i.test(artwork)) {
            const thumbFallback = artwork.replace(/\.webp$/i, '_thumb.webp');
            appendUnique(resolveArtworkPath(thumbFallback, false));
        }
    }

    appendUnique('./assets/default_artwork.png');
    return candidates;
}

export function updateNowPlayingView(song) {
    const {
        nowPlayingArtworkContainer,
        nowPlayingTitle,
        nowPlayingArtist,
        hubLinkContainer
    } = elements;

    const localPlayer = document.getElementById('main-player');

    if (localPlayer) {
        document.body.appendChild(localPlayer);
        localPlayer.style.display = 'none';
    }

    nowPlayingArtworkContainer.innerHTML = '';
    hubLinkContainer.innerHTML = '';
    nowPlayingArtworkContainer.classList.remove('video-mode');

    if (!song) {
        const img = document.createElement('img');
        img.src = './assets/default_artwork.png';
        nowPlayingArtworkContainer.appendChild(img);
        setEqualizerColorFromArtwork(img);

    } else if (song.type === 'youtube') {
        nowPlayingArtworkContainer.classList.add('video-mode');
        const videoId = getYoutubeVideoId(song.sourceURL || song.path);
        if (videoId) {
            const iframe = document.createElement('iframe');
            iframe.width = '100%';
            iframe.height = '100%';
            iframe.src = `https://www.youtube.com/embed/${videoId}?autoplay=1&controls=0&fs=0&iv_load_policy=3&modestbranding=1&origin=${window.location.protocol}//${window.location.host}`;
            iframe.setAttribute('frameborder', '0');
            iframe.setAttribute('allow', 'autoplay; encrypted-media');
            nowPlayingArtworkContainer.appendChild(iframe);
        }

        const artworkImage = new Image();
        artworkImage.crossOrigin = "Anonymous";
        artworkImage.onload = () => setEqualizerColorFromArtwork(artworkImage);
        artworkImage.src = song.artwork;

    } else {
        const img = document.createElement('img');
        img.crossOrigin = "Anonymous";
        img.onload = () => setEqualizerColorFromArtwork(img);

        const masterSong = state.libraryByPath.get(song.path) || song;
        const album = state.albums.get(masterSong.albumKey);

        let artwork;
        if (masterSong.album === 'Unknown Album' || (album && album.title === 'Unknown Album')) {
            artwork = null;
        } else {
            artwork = masterSong.artwork || (album ? album.artwork : null);
        }

        const artworkCandidates = buildArtworkCandidates(artwork);
        let artworkIndex = 0;

        img.onerror = () => {
            const failedSrc = artworkCandidates[artworkIndex];
            artworkIndex += 1;
            if (artworkIndex < artworkCandidates.length) {
                console.warn('[NowPlaying] Artwork load failed, fallback to next source:', failedSrc);
                img.src = artworkCandidates[artworkIndex];
                return;
            }
            console.warn('[NowPlaying] Artwork load failed on all candidates:', artworkCandidates);
            img.onerror = null;
        };
        img.src = artworkCandidates[artworkIndex];

        if (masterSong.hasVideo && localPlayer) {
            nowPlayingArtworkContainer.classList.add('video-mode');
            localPlayer.poster = img.src;
            localPlayer.style.display = 'block';
            nowPlayingArtworkContainer.appendChild(localPlayer);
        } else {
            nowPlayingArtworkContainer.classList.remove('video-mode');
            nowPlayingArtworkContainer.appendChild(img);
        }
    }

    if (song && song.hubUrl) {
        const hubButton = document.createElement('button');
        hubButton.className = 'hub-link-button-small';
        hubButton.textContent = '🔗 公式リンクを開く';
        hubButton.addEventListener('click', () => electronAPI.send('open-external-link', song.hubUrl));
        hubLinkContainer.appendChild(hubButton);
    }

    const titleEl = nowPlayingTitle.querySelector('.marquee-content span') || nowPlayingTitle;
    if (titleEl) {
        titleEl.textContent = song ? formatSongTitle(song.title) : '曲を選択してください';
    }

    const artistEl = nowPlayingArtist.querySelector('.marquee-content span') || nowPlayingArtist;
    if (artistEl) {
        artistEl.textContent = song ? song.artist : '';
    }

    // 曲更新時にマルキーを再計算して、旧複製テキストの残留を防ぐ
    requestAnimationFrame(() => {
        checkTextOverflow(nowPlayingTitle);
        checkTextOverflow(nowPlayingArtist);
    });
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
