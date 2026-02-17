// src/renderer/js/ui/now-playing.js

import { state, elements } from '../core/state.js';
import { setEqualizerColorFromArtwork } from '../features/player.js';
import { resolveArtworkPath, formatSongTitle, checkTextOverflow } from './utils.js';
const electronAPI = window.electronAPI;

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
    console.log('[Debug:NowPlaying] updateNowPlayingView 開始 - 曲:', song?.title);

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

    if (nowPlayingArtworkContainer) nowPlayingArtworkContainer.innerHTML = '';
    if (hubLinkContainer) hubLinkContainer.innerHTML = '';
    if (nowPlayingArtworkContainer) nowPlayingArtworkContainer.classList.remove('video-mode');

    if (!song) {
        console.log('[Debug:NowPlaying] 曲が指定されていないため、デフォルト画像を表示します。');
        const img = document.createElement('img');
        img.src = './assets/default_artwork.png';
        if (nowPlayingArtworkContainer) nowPlayingArtworkContainer.appendChild(img);
        setEqualizerColorFromArtwork(img);

    } else if (song.type === 'youtube') {
        console.log('[Debug:NowPlaying] YouTube モードで描画します。');
        if (nowPlayingArtworkContainer) nowPlayingArtworkContainer.classList.add('video-mode');
        const videoId = getYoutubeVideoId(song.sourceURL || song.path);
        if (videoId) {
            const iframe = document.createElement('iframe');
            iframe.width = '100%';
            iframe.height = '100%';
            iframe.src = `https://www.youtube.com/embed/${videoId}?autoplay=1&controls=0&fs=0&iv_load_policy=3&modestbranding=1&origin=${window.location.protocol}//${window.location.host}`;
            iframe.setAttribute('frameborder', '0');
            iframe.setAttribute('allow', 'autoplay; encrypted-media');
            if (nowPlayingArtworkContainer) nowPlayingArtworkContainer.appendChild(iframe);
        }

        const artworkImage = new Image();
        artworkImage.crossOrigin = "Anonymous";
        artworkImage.onload = () => setEqualizerColorFromArtwork(artworkImage);
        artworkImage.src = song.artwork;

    } else {
        console.log('[Debug:NowPlaying] ローカル曲として描画します。');
        const img = document.createElement('img');
        img.crossOrigin = "Anonymous";
        img.onload = () => {
            console.log('[Debug:NowPlaying] アートワーク画像の読み込みが完了しました。');
            setEqualizerColorFromArtwork(img);
        };

        const masterSong = state.library.find(s => s.path === song.path) || song;
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

        if (masterSong.hasVideo && localPlayer && nowPlayingArtworkContainer) {
            nowPlayingArtworkContainer.classList.add('video-mode');
            localPlayer.poster = img.src;
            localPlayer.style.display = 'block';
            nowPlayingArtworkContainer.appendChild(localPlayer);
        } else if (nowPlayingArtworkContainer) {
            nowPlayingArtworkContainer.classList.remove('video-mode');
            nowPlayingArtworkContainer.appendChild(img);
        }
    }

    if (song && song.hubUrl && hubLinkContainer) {
        const hubButton = document.createElement('button');
        hubButton.className = 'hub-link-button-small';
        hubButton.textContent = '🔗 公式リンクを開く';
        hubButton.addEventListener('click', () => electronAPI.send('open-external-link', song.hubUrl));
        hubLinkContainer.appendChild(hubButton);
    }

    // タイトルの更新
    const titleSpan = nowPlayingTitle ? nowPlayingTitle.querySelector('.marquee-content span') : null;
    if (titleSpan) {
        titleSpan.textContent = song ? formatSongTitle(song.title) : '曲を選択してください';
        console.log('[Debug:NowPlaying] タイトルを更新しました:', titleSpan.textContent);
    } else {
        console.error('[Debug:NowPlaying] エラー: タイトルを表示する DOM 要素 (.marquee-content span) が見つかりません。');
    }

    // アーティストの更新
    const artistSpan = nowPlayingArtist ? nowPlayingArtist.querySelector('.marquee-content span') : null;
    if (artistSpan) {
        artistSpan.textContent = song ? song.artist : '';
        console.log('[Debug:NowPlaying] アーティストを更新しました:', artistSpan.textContent);
    } else {
        console.error('[Debug:NowPlaying] エラー: アーティストを表示する DOM 要素 (.marquee-content span) が見つかりません。');
    }

    // 曲更新時にマルキーを再計算して、旧複製テキストの残留を防ぐ
    requestAnimationFrame(() => {
        checkTextOverflow(nowPlayingTitle);
        checkTextOverflow(nowPlayingArtist);
    });
}
