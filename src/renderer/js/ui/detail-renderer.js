// src/renderer/js/ui/detail-renderer.js

import { state, elements } from '../state.js';
import { showAlbum } from '../navigation.js';
import { playSong } from '../playback-manager.js';
import { createAlbumGridItem } from './element-factory.js';
import { createPlaylistArtwork } from './playlist-artwork.js';
import { formatTime, resolveArtworkPath } from './utils.js';
import {
    createListHeader,
    setupSongListScroller,
    initListHeaderResizing
} from './list-renderer.js';
import { clearMainContent } from './view-renderer.js';
import { updateListSpacer } from '../ui.js'; // 追加
const electronAPI = window.electronAPI;

// モジュールスコープでスクロール位置を記憶
let lastScrollPositions = {};

/**
 * アルバム詳細ビューを描画する
 */
export function renderAlbumDetailView(album) {
    clearMainContent();
    state.currentlyViewedSongs = album.songs;
    const viewWrapper = document.createElement('div');
    viewWrapper.className = 'view-container';
    const totalDuration = album.songs.reduce((sum, song) => sum + (song.duration || 0), 0);
    viewWrapper.innerHTML = `
        <div class="detail-header">
            <img class="detail-art-img lazy-load">
            <div class="detail-info">
                <h1>${album.title}</h1>
                <p>${album.artist}</p>
                <p>${album.songs.length} 曲, ${formatTime(totalDuration)}</p>
                <div class="detail-actions"><button class="play-all-btn">▶ すべて再生</button></div>
            </div>
        </div>
        ${createListHeader()}
    `;
    const listElement = document.createElement('div');
    listElement.id = 'a-detail-list';
    listElement.className = 'music-list';

    viewWrapper.appendChild(listElement);
    elements.mainContent.appendChild(viewWrapper);

    const scroller = setupSongListScroller(listElement, album.songs, {
        contextView: 'album'
    });

    // スペーサーを更新
    updateListSpacer();

    initListHeaderResizing(viewWrapper);

    const artImg = viewWrapper.querySelector('.detail-art-img');

    let artworkToUse = album.artwork;
    if (!artworkToUse && album.songs && album.songs.length > 0) {
        const songWithArt = album.songs.find(s => s.artwork);
        if (songWithArt) {
            artworkToUse = songWithArt.artwork;
        }
    }
    artImg.dataset.src = resolveArtworkPath(artworkToUse, false);

    viewWrapper.querySelector('.play-all-btn').addEventListener('click', () => playSong(0, album.songs));

    window.observeNewArtworks(viewWrapper);
    return scroller;
}

/**
 * アーティスト詳細ビューを描画する
 */
export function renderArtistDetailView(artist) {
    clearMainContent();
    state.currentlyViewedSongs = artist.songs;
    const viewWrapper = document.createElement('div');
    viewWrapper.className = 'view-container';
    const artistAlbums = [...state.albums.values()].filter(album => album.artist === artist.name);
    viewWrapper.innerHTML = `
        <div class="detail-header">
            <img class="detail-art-img artist-detail-art-round lazy-load">
            <div class="detail-info">
                <h1>${artist.name}</h1>
                <p>${artistAlbums.length}枚のアルバム, ${artist.songs.length}曲</p>
            </div>
        </div>
        <h2>アルバム</h2>
    `;
    const grid = document.createElement('div');
    grid.className = 'album-grid';
    if (artistAlbums.length === 0) {
        grid.innerHTML = `<div class="placeholder">このアーティストのアルバムは見つかりません</div>`;
    } else {
        artistAlbums.forEach(album => {
            const albumKey = `${album.title}---${album.artist}`;
            const albumItem = createAlbumGridItem(albumKey, album, electronAPI);
            albumItem.addEventListener('click', () => showAlbum(albumKey));
            grid.appendChild(albumItem);
        });
    }
    viewWrapper.appendChild(grid);
    elements.mainContent.appendChild(viewWrapper);

    // スペーサーを更新
    updateListSpacer();

    const artImg = viewWrapper.querySelector('.detail-art-img');
    artImg.dataset.src = resolveArtworkPath(artist.artwork, false);

    window.observeNewArtworks(viewWrapper);
    return null;
}

/**
 * プレイリスト詳細ビューを描画する
 */
export function renderPlaylistDetailView(playlistDetails = {}) {
    const { name: playlistName = '不明なプレイリスト', songs = [], artworks = [] } = playlistDetails;

    clearMainContent();
    state.currentlyViewedSongs = songs;
    const viewWrapper = document.createElement('div');
    viewWrapper.className = 'view-container';
    const totalDuration = songs.reduce((sum, song) => sum + (song.duration || 0), 0);
    viewWrapper.innerHTML = `
        <div class="detail-header">
            <div class="playlist-art-collage detail-art-img"></div>
            <div class="detail-info">
                <h1>${playlistName}</h1>
                <p>${songs.length} 曲, ${formatTime(totalDuration)}</p>
                <div class="detail-actions"><button class="play-all-btn">▶ すべて再生</button></div>
            </div>
        </div>
        ${createListHeader()}
    `;
    const listElement = document.createElement('div');
    listElement.id = 'p-detail-list';
    listElement.className = 'music-list';

    const artworkContainer = viewWrapper.querySelector('.playlist-art-collage');
    const resolver = (artwork) => resolveArtworkPath(artwork, true);
    createPlaylistArtwork(artworkContainer, artworks, resolver);

    viewWrapper.appendChild(listElement);
    elements.mainContent.appendChild(viewWrapper);

    const savedScrollTop = lastScrollPositions[playlistName] || 0;

    const scroller = setupSongListScroller(listElement, songs, {
        contextView: 'playlist',
        playlistName: playlistName,
        initialScrollTop: savedScrollTop,
        saveScrollPosition: (scrollTop) => {
            lastScrollPositions[playlistName] = scrollTop;
        }
    });

    if (savedScrollTop > 0) {
        delete lastScrollPositions[playlistName];
    }

    // スペーサーを更新
    updateListSpacer();

    initListHeaderResizing(viewWrapper);

    viewWrapper.querySelector('.play-all-btn').addEventListener('click', () => playSong(0, songs));

    window.observeNewArtworks(viewWrapper);
    return scroller;
}