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
import { clearMainContent } from './view-renderer.js'; // clearMainContent は view-renderer から
const { ipcRenderer } = require('electron');

// モジュールスコープでスクロール位置を記憶
let lastScrollPositions = {};

/**
 * アルバム詳細ビューを描画する
 * @param {object} album - アルバムオブジェクト
 * @returns {VirtualScroller|null} 生成された VirtualScroller インスタンス
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
    
    initListHeaderResizing(viewWrapper);
    
    const artImg = viewWrapper.querySelector('.detail-art-img');
    artImg.dataset.src = resolveArtworkPath(album.artwork, false);
    
    viewWrapper.querySelector('.play-all-btn').addEventListener('click', () => playSong(0, album.songs));
    
    window.observeNewArtworks(viewWrapper);
    return scroller; // VirtualScroller インスタンスを返す
}

/**
 * アーティスト詳細ビューを描画する
 * @param {object} artist - アーティストオブジェクト
 * @returns {null} このビューは VirtualScroller を使用しない
 */
export function renderArtistDetailView(artist) {
    clearMainContent();
    state.currentlyViewedSongs = artist.songs; // アーティストの全曲をセット
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
            const albumItem = createAlbumGridItem(albumKey, album, ipcRenderer);
            albumItem.addEventListener('click', () => showAlbum(albumKey));
            grid.appendChild(albumItem);
        });
    }
    viewWrapper.appendChild(grid);
    elements.mainContent.appendChild(viewWrapper);

    const artImg = viewWrapper.querySelector('.detail-art-img');
    artImg.dataset.src = resolveArtworkPath(artist.artwork, false);

    window.observeNewArtworks(viewWrapper);
    return null; // このビューはスクローラーを返さない
}

/**
 * プレイリスト詳細ビューを描画する
 * @param {object} playlistDetails - プレイリスト詳細
 * @returns {VirtualScroller|null} 生成された VirtualScroller インスタンス
 */
export function renderPlaylistDetailView(playlistDetails) {
    const { name: playlistName, songs, artworks } = playlistDetails;

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
        delete lastScrollPositions[playlistName]; // 復元したら削除
    }
    
    initListHeaderResizing(viewWrapper);

    viewWrapper.querySelector('.play-all-btn').addEventListener('click', () => playSong(0, songs));
    
    window.observeNewArtworks(viewWrapper);
    return scroller; // VirtualScroller インスタンスを返す
}