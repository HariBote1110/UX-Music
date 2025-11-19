import { state, elements } from './state.js';
import { setupSongListScroller, createListHeader, initListHeaderResizing } from './ui/list-renderer.js'; // ★★★ 追加: 必要な関数をインポート
import { resolveArtworkPath, formatSongTitle } from './ui/utils.js';
import { setEqualizerColorFromArtwork } from './player.js';
const { ipcRenderer } = require('electron');

export function initUI() {
    // UI初期化ロジックがあればここに記述
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

        const masterSong = state.library.find(s => s.path === song.path) || song;
        const album = state.albums.get(masterSong.albumKey);
        
        let artwork;
        if (masterSong.album === 'Unknown Album' || (album && album.title === 'Unknown Album')) {
            artwork = null;
        } else {
            artwork = masterSong.artwork || (album ? album.artwork : null);
        }

        img.src = resolveArtworkPath(artwork, false);

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
        hubButton.addEventListener('click', () => ipcRenderer.send('open-external-link', song.hubUrl));
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
    // flexレイアウトで縦に並べるためのスタイル（views.cssの想定）
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
        return;
    }

    setupSongListScroller(listContainer, displaySongs, {
        contextView: 'track-view'
    });
    
    // 列リサイズの初期化
    initListHeaderResizing(viewWrapper);
}