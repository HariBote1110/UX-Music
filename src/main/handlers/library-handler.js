// src/main/handlers/library-handler.js

const { ipcMain, app, dialog } = require('electron'); // dialog は不要になる
const path = require('path');
const fs = require('fs');
// ▼▼▼ 削除 (import-handler.js へ移動) ▼▼▼
// const crypto = require('crypto');
// const { scanPaths, parseFiles, analyzeLoudness } = require('../file-scanner');
// const os = require('os');
// const { sanitize } = require('../utils');
// const sharp = require('sharp');
// const { Worker } = require('worker_threads');
// ▲▲▲ 削除 ▲▲▲
const { analyzeLoudness } = require('../file-scanner'); // analyzeLoudness は残す
const NodeID3 = require('node-id3');
// ▼▼▼ 追加 ▼▼▼
// import-handler から saveArtworkToFile をインポート
const { saveArtworkToFile } = require('./import-handler'); 
// ▲▲▲ 追加 ▲▲▲


let libraryStore;
let loudnessStore;
let settingsStore;
let playCountsStore;
let albumsStore;

// ▼▼▼ 削除 (import-handler.js へ移動) ▼▼▼
// async function saveArtworkToFile(picture, albumArtist, albumTitle) { ... }
// function addSongsToLibraryAndSave(newSongs) { ... }
// ▲▲▲ 削除 ▲▲▲


function registerLibraryHandlers(stores, sendToAllWindows) {
    libraryStore = stores.library;
    loudnessStore = stores.loudness;
    settingsStore = stores.settings;
    playCountsStore = stores.playCounts;
    albumsStore = stores.albums;

    ipcMain.on('request-bpm-analysis', async (event, song) => {
        const { analyzeBPM } = require('../file-scanner');
        const bpm = await analyzeBPM(song.path);
        if (bpm !== null) {
            const library = libraryStore.load() || [];
            const songIndex = library.findIndex(s => s.path === song.path);
            if (songIndex > -1) {
                library[songIndex].bpm = bpm;
                libraryStore.save(library);
                sendToAllWindows('bpm-analysis-complete', library[songIndex]);
            }
        }
    });

    ipcMain.on('request-loudness-analysis', async (event, filePath) => {
        const result = await analyzeLoudness(filePath); // file-scanner の analyzeLoudness
        if (result.success) {
            const loudnessData = loudnessStore.load();
            loudnessData[filePath] = result.loudness;
            loudnessStore.save(loudnessData);
        }
        event.sender.send('loudness-analysis-result', result);
    });

    // ▼▼▼ 削除 (import-handler.js へ移動) ▼▼▼
    // ipcMain.on('start-scan-paths', async (event, paths) => { ... });
    // ▲▲▲ 削除 ▲▲▲

    ipcMain.handle('get-loudness-value', (event, songPath) => (loudnessStore.load() || {})[songPath] || null);

    ipcMain.on('request-initial-library', (event) => {
        const songs = libraryStore.load() || [];
        const albums = albumsStore.load() || {};
        event.sender?.send('load-library', { songs, albums });
    });


    ipcMain.on('debug-reset-library', (event) => {
        try {
            libraryStore.save([]);
            loudnessStore.save({});
            playCountsStore.save({});
            albumsStore.save({});
            const artworksDir = path.join(app.getPath('userData'), 'Artworks');
            if (fs.existsSync(artworksDir)) fs.rmSync(artworksDir, { recursive: true, force: true });
            const libraryPath = settingsStore.load().libraryPath;
            if (libraryPath && fs.existsSync(libraryPath)) {
                fs.readdirSync(libraryPath).forEach(file => {
                     const curPath = path.join(libraryPath, file);
                     fs.rmSync(curPath, { recursive: true, force: true });
                });
            }
            console.log('[DEBUG] Library has been reset completely.');
            event.sender?.send('force-reload-library');
        } catch (error) {
            console.error('[DEBUG] Failed to reset library:', error);
        }
    });

    ipcMain.handle('edit-metadata', async (event, { filePath, newTags }) => {
        try {
            const tagsToWrite = { ...newTags };
            let artworkResult = undefined; 

            if (tagsToWrite.image === null) {
                tagsToWrite.image = undefined; 
                artworkResult = null; 
            } else if (tagsToWrite.image && tagsToWrite.image.imageBuffer) {
                // ▼▼▼ 修正箇所 (import-handler.js からインポートした関数を使用) ▼▼▼
                artworkResult = await saveArtworkToFile({ data: tagsToWrite.image.imageBuffer }, newTags.artist || newTags.albumartist, newTags.album);
                // ▲▲▲ 修正箇所 ▲▲▲
                
                // node-id3 は Buffer を期待するので、imageBuffer は削除しない
                // tagsToWrite.image.imageBuffer = undefined; 
            } else {
                 delete tagsToWrite.image;
            }

            // node-id3 に渡すタグオブジェクトから imageBuffer を除外（もしあれば）
            // imageBuffer は saveArtworkToFile 専用
            if (tagsToWrite.image && tagsToWrite.image.imageBuffer) {
                tagsToWrite.image = {
                    ...tagsToWrite.image, // mime, type, description など
                    imageBuffer: tagsToWrite.image.imageBuffer // Buffer は渡す
                };
                // imageBuffer は saveArtworkToFile でのみ使い、node-id3 には渡さない場合
                // delete tagsToWrite.image.imageBuffer; 
                // → NodeID3.write が imageBuffer を期待しているため、削除しない
            }

            const success = NodeID3.write(tagsToWrite, filePath);

            if (!success) {
                 console.error(`NodeID3.write failed for ${filePath}`);
                 return { success: false, message: 'ファイルへのタグ書き込みに失敗しました。' };
            }

            const library = libraryStore.load() || [];
            const songIndex = library.findIndex(s => s.path === filePath);
            if (songIndex === -1) {
                return { success: false, message: 'ライブラリに対象の曲が見つかりません。' };
            }
            
            const oldSong = library[songIndex]; // 更新前の曲情報
            const updatedSong = { ...oldSong };
            
            // タグ情報を更新
            updatedSong.title = newTags.title ?? updatedSong.title;
            updatedSong.artist = newTags.artist ?? updatedSong.artist;
            updatedSong.albumartist = newTags.albumartist ?? updatedSong.albumartist; // albumartist も更新
            updatedSong.album = newTags.album ?? updatedSong.album;
            updatedSong.genre = newTags.genre ?? updatedSong.genre;

            if (artworkResult !== undefined) {
                 updatedSong.artwork = artworkResult;
            }

            // アルバムキーを再計算
            const albumArtistKey = updatedSong.albumartist || updatedSong.artist || 'Unknown Artist';
            const albumKey = `${albumArtistKey}---${updatedSong.album || 'Unknown Album'}`;
            const oldAlbumKey = oldSong.albumKey; // 更新前のキー
            updatedSong.albumKey = albumKey; 

            library[songIndex] = updatedSong;
            libraryStore.save(library);

            // albums.json の更新
            const albumsData = albumsStore.load() || {};
            let albumNeedsUpdate = false;
            
            // アルバム情報が変わった場合
            if (oldAlbumKey !== newAlbumKey) {
                // 古いアルバムから曲を削除
                if (albumsData[oldAlbumKey]) {
                    albumsData[oldAlbumKey].songs = albumsData[oldAlbumKey].songs.filter(p => p !== filePath);
                    // 曲がなくなったらアルバムごと削除するなども検討
                    albumNeedsUpdate = true;
                }
            }

            // 新しいアルバム（または既存のアルバム）に曲を追加/情報を更新
            if (!albumsData[newAlbumKey]) {
                // 新しいアルバムエントリを作成
                albumsData[newAlbumKey] = {
                    title: updatedSong.album,
                    artist: albumArtistKey,
                    songs: [filePath],
                    artwork: updatedSong.artwork
                };
                albumNeedsUpdate = true;
            } else {
                // 既存のアルバム情報を更新
                if (!albumsData[newAlbumKey].songs.includes(filePath)) {
                    albumsData[newAlbumKey].songs.push(filePath);
                    albumNeedsUpdate = true;
                }
                // アートワークが変更された場合
                if (artworkResult !== undefined && JSON.stringify(albumsData[newAlbumKey].artwork) !== JSON.stringify(artworkResult)) {
                    albumsData[newAlbumKey].artwork = artworkResult;
                    albumNeedsUpdate = true;
                }
            }
            
            if (albumNeedsUpdate) {
                albumsStore.save(albumsData);
            }

            return { success: true, updatedSong: updatedSong };

        } catch (error) {
            console.error(`メタデータ編集エラー (${filePath}):`, error);
             if (error instanceof Error) {
                 return { success: false, message: `タグ書き込みエラー: ${error.message}` };
             }
             return { success: false, message: '不明なエラーが発生しました。' };
        }
    });
}

module.exports = {
    registerLibraryHandlers
    // saveArtworkToFile は import-handler.js からエクスポートされる
};