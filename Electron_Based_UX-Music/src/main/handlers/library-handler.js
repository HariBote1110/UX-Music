// src/main/handlers/library-handler.js

const { ipcMain, app, dialog } = require('electron'); // dialog は不要になる
const path = require('path');
const fs = require('fs');
// ▼▼▼ 変更: getSampleRate をインポート ▼▼▼
const { analyzeLoudness, getSampleRate } = require('../file-scanner'); 
// ▲▲▲ 変更ここまで ▲▲▲
const NodeID3 = require('node-id3');
const { saveArtworkToFile } = require('./import-handler'); 


let libraryStore;
let loudnessStore;
let settingsStore;
let playCountsStore;
let albumsStore;

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
        const result = await analyzeLoudness(filePath);
        if (result.success) {
            const loudnessData = loudnessStore.load();
            loudnessData[filePath] = result.loudness;
            loudnessStore.save(loudnessData);
        }
        if (event.sender && !event.sender.isDestroyed()) {
        event.sender.send('loudness-analysis-result', result);
        }
    });

    ipcMain.handle('get-loudness-value', (event, songPath) => (loudnessStore.load() || {})[songPath] || null);

    ipcMain.on('request-initial-library', (event) => {
        const songs = libraryStore.load() || [];
        const albums = albumsStore.load() || {};
        if(event.sender && !event.sender.isDestroyed()) event.sender.send('load-library', { songs, albums });
        
        // ▼▼▼ 追加: ライブラリ読み込み後にSRマイグレーションをチェック ▼▼▼
        checkAndMigrateSampleRates(songs, sendToAllWindows);
        // ▲▲▲ 追加ここまで ▲▲▲
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
            if(event.sender && !event.sender.isDestroyed()) event.sender.send('force-reload-library');
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
                artworkResult = await saveArtworkToFile({ data: tagsToWrite.image.imageBuffer }, newTags.artist || newTags.albumartist, newTags.album);
            } else {
                 delete tagsToWrite.image;
            }

            if (tagsToWrite.image && tagsToWrite.image.imageBuffer) {
                tagsToWrite.image = {
                    ...tagsToWrite.image, 
                    imageBuffer: tagsToWrite.image.imageBuffer 
                };
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
            
            const oldSong = library[songIndex]; 
            const updatedSong = { ...oldSong };
            
            updatedSong.title = newTags.title ?? updatedSong.title;
            updatedSong.artist = newTags.artist ?? updatedSong.artist;
            updatedSong.albumartist = newTags.albumartist ?? updatedSong.albumartist; 
            updatedSong.album = newTags.album ?? updatedSong.album;
            updatedSong.genre = newTags.genre ?? updatedSong.genre;

            if (artworkResult !== undefined) {
                 updatedSong.artwork = artworkResult;
            }

            const albumArtistKey = updatedSong.albumartist || updatedSong.artist || 'Unknown Artist';
            const albumKey = `${albumArtistKey}---${updatedSong.album || 'Unknown Album'}`;
            const oldAlbumKey = oldSong.albumKey; 
            updatedSong.albumKey = albumKey; 

            library[songIndex] = updatedSong;
            libraryStore.save(library);

            const albumsData = albumsStore.load() || {};
            let albumNeedsUpdate = false;
            
            if (oldAlbumKey !== albumKey) { // newAlbumKey was undefined in snippet, using albumKey
                if (albumsData[oldAlbumKey]) {
                    albumsData[oldAlbumKey].songs = albumsData[oldAlbumKey].songs.filter(p => p !== filePath);
                    albumNeedsUpdate = true;
                }
            }

            if (!albumsData[albumKey]) {
                albumsData[albumKey] = {
                    title: updatedSong.album,
                    artist: albumArtistKey,
                    songs: [filePath],
                    artwork: updatedSong.artwork
                };
                albumNeedsUpdate = true;
            } else {
                if (!albumsData[albumKey].songs.includes(filePath)) {
                    albumsData[albumKey].songs.push(filePath);
                    albumNeedsUpdate = true;
                }
                if (artworkResult !== undefined && JSON.stringify(albumsData[albumKey].artwork) !== JSON.stringify(artworkResult)) {
                    albumsData[albumKey].artwork = artworkResult;
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

// ▼▼▼ 追加: マイグレーション処理関数 ▼▼▼
/**
 * ライブラリ内の曲をチェックし、sampleRateが欠落している場合はスキャンして更新する
 */
async function checkAndMigrateSampleRates(songs, sendToAllWindows) {
    let updatedCount = 0;
    // 更新が必要な曲をリストアップ
    const migrationList = [];
    
    for (let i = 0; i < songs.length; i++) {
        const song = songs[i];
        // sampleRateが無い、かつローカルファイルの場合
        if (!song.sampleRate && song.type === 'local' && song.path) {
            migrationList.push({ index: i, path: song.path });
        }
    }

    if (migrationList.length === 0) return; // 更新対象なし

    console.log(`[Library] Starting Sample Rate migration for ${migrationList.length} songs...`);

    // 順次スキャンして更新
    for (const item of migrationList) {
        const sr = await getSampleRate(item.path);
        if (sr) {
            songs[item.index].sampleRate = sr;
            // ハイレゾフラグも念のため再判定
            songs[item.index].isHiRes = (sr > 48000); 
            updatedCount++;
        }
    }

    if (updatedCount > 0) {
        // 保存
        libraryStore.save(songs);
        console.log(`[Library] Migration complete. Updated ${updatedCount} songs.`);
        
        // レンダラーへ最新状態を送信（再読み込みを促す）
        // 既存の 'load-library' イベントを再送することでUIも最新化されます
        const albums = albumsStore.load() || {};
        sendToAllWindows('load-library', { songs, albums });
    }
}
// ▲▲▲ 追加ここまで ▲▲▲

module.exports = {
    registerLibraryHandlers
};