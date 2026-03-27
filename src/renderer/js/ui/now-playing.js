// src/renderer/js/ui/now-playing.js

import { state, elements } from '../core/state.js';
import { setEqualizerColorFromArtwork, getCurrentTime, isPlaying } from '../features/player.js';
import { resolveArtworkPath, formatSongTitle, checkTextOverflow } from './utils.js';
const electronAPI = window.electronAPI;

const VIDEO_PREVIEW_EXTENSIONS = ['.mp4', '.m4v', '.mov', '.webm', '.ogv'];
const VIDEO_SYNC_INTERVAL_MS = 250;
const VIDEO_SYNC_TOLERANCE_SECONDS = 0.45;

let sidebarPreviewVideo = null;
let sidebarPreviewTimerId = null;

function isWailsRuntime() {
    return window.go !== undefined;
}

function clearSidebarPreviewVideo() {
    if (sidebarPreviewTimerId !== null) {
        clearInterval(sidebarPreviewTimerId);
        sidebarPreviewTimerId = null;
    }
    if (sidebarPreviewVideo) {
        sidebarPreviewVideo.pause();
        sidebarPreviewVideo.removeAttribute('src');
        sidebarPreviewVideo.load();
        sidebarPreviewVideo.remove();
        sidebarPreviewVideo = null;
    }
}

function buildVideoPreviewURL(path) {
    if (typeof path !== 'string' || path.trim() === '') return '';
    const normalisedPath = path.replace(/\\/g, '/');

    if (isWailsRuntime()) {
        const relativePath = normalisedPath.replace(/^[/\\]+/, '');
        const safePath = encodeURI(relativePath).replace(/#/g, '%23');
        return `/safe-media/${safePath}`;
    }

    const safePath = encodeURI(normalisedPath).replace(/#/g, '%23');
    return `file://${safePath}`;
}

function isVideoPreviewSupported(path) {
    if (typeof path !== 'string') return false;
    const lowerPath = path.trim().toLowerCase();
    return VIDEO_PREVIEW_EXTENSIONS.some(ext => lowerPath.endsWith(ext));
}

function syncSidebarPreviewVideo(video) {
    if (!video) return;
    const targetTime = getCurrentTime();

    if (Number.isFinite(targetTime) && video.readyState >= 1 && Math.abs(video.currentTime - targetTime) > VIDEO_SYNC_TOLERANCE_SECONDS) {
        try {
            video.currentTime = Math.max(0, targetTime);
        } catch (error) {
            // Ignore sporadic seek errors during source warm-up.
        }
    }

    if (isPlaying()) {
        if (video.paused) {
            const playPromise = video.play();
            if (playPromise && typeof playPromise.catch === 'function') {
                playPromise.catch(() => { });
            }
        }
    } else if (!video.paused) {
        video.pause();
    }
}

function attachSidebarPreviewVideo(container, songPath, posterSrc) {
    if (!container || !songPath) return false;
    if (!isVideoPreviewSupported(songPath)) {
        console.log('[NowPlaying][Video] 右サイドバー映像プレビュー対象外の拡張子です:', songPath);
        return false;
    }

    const sourceURL = buildVideoPreviewURL(songPath);
    if (!sourceURL) {
        console.warn('[NowPlaying][Video] 映像プレビュー用URLの生成に失敗しました。');
        return false;
    }

    clearSidebarPreviewVideo();

    const preview = document.createElement('video');
    preview.muted = true;
    preview.playsInline = true;
    preview.autoplay = false;
    preview.preload = 'auto';
    preview.controls = false;
    preview.disablePictureInPicture = true;
    preview.src = sourceURL;
    if (posterSrc) preview.poster = posterSrc;

    preview.addEventListener('loadedmetadata', () => {
        syncSidebarPreviewVideo(preview);
    });

    preview.addEventListener('error', () => {
        console.warn('[NowPlaying][Video] 右サイドバー映像プレビューの読み込みに失敗しました:', { songPath, sourceURL });
    });

    container.appendChild(preview);
    sidebarPreviewVideo = preview;
    sidebarPreviewTimerId = window.setInterval(() => {
        syncSidebarPreviewVideo(preview);
    }, VIDEO_SYNC_INTERVAL_MS);
    syncSidebarPreviewVideo(preview);

    console.log('[NowPlaying][Video] 右サイドバー映像プレビューを開始しました:', songPath);
    return true;
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

function updateFooterArtwork(src) {
    const footerArtwork = document.getElementById('footer-artwork');
    if (footerArtwork) footerArtwork.src = src;
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

    clearSidebarPreviewVideo();

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
        updateFooterArtwork('./assets/default_artwork.png');

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
        updateFooterArtwork(song.artwork || './assets/default_artwork.png');

    } else {
        console.log('[Debug:NowPlaying] ローカル曲として描画します。');
        const img = document.createElement('img');
        img.crossOrigin = "Anonymous";
        img.onload = () => {
            console.log('[Debug:NowPlaying] アートワーク画像の読み込みが完了しました。');
            setEqualizerColorFromArtwork(img);
        };

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
        let resolvedArtworkSrc = artworkCandidates[artworkIndex];
        updateFooterArtwork(resolvedArtworkSrc);

        img.onerror = () => {
            const failedSrc = resolvedArtworkSrc;
            artworkIndex += 1;
            if (artworkIndex < artworkCandidates.length) {
                console.warn('[NowPlaying] Artwork load failed, fallback to next source:', failedSrc);
                resolvedArtworkSrc = artworkCandidates[artworkIndex];
                img.src = resolvedArtworkSrc;
                return;
            }
            console.warn('[NowPlaying] Artwork load failed on all candidates:', artworkCandidates);
            img.onerror = null;
        };
        img.src = resolvedArtworkSrc;

        if (masterSong.hasVideo && nowPlayingArtworkContainer) {
            nowPlayingArtworkContainer.classList.add('video-mode');
            if (isWailsRuntime()) {
                const previewAttached = attachSidebarPreviewVideo(nowPlayingArtworkContainer, masterSong.path, resolvedArtworkSrc);
                if (!previewAttached) {
                    nowPlayingArtworkContainer.appendChild(img);
                }
            } else if (localPlayer) {
                localPlayer.poster = resolvedArtworkSrc;
                localPlayer.style.display = 'block';
                nowPlayingArtworkContainer.appendChild(localPlayer);
            } else {
                nowPlayingArtworkContainer.appendChild(img);
            }
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
