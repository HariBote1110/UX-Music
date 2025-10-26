const { ipcMain, app, dialog } = require('electron');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');
const { scanPaths, parseFiles, analyzeLoudness } = require('../file-scanner');
const os = require('os');
const { sanitize } = require('../utils');
const sharp = require('sharp');
const { Worker } = require('worker_threads');
const NodeID3 = require('node-id3'); // ★★★ node-id3 を require ★★★

let libraryStore;
let loudnessStore;
let settingsStore;
let playCountsStore;
let albumsStore;

async function saveArtworkToFile(picture, albumArtist, albumTitle) {
    if (!picture || !picture.data) return null;
    const artworksDir = path.join(app.getPath('userData'), 'Artworks');
    const thumbnailsDir = path.join(artworksDir, 'thumbnails');
    if (!fs.existsSync(artworksDir)) fs.mkdirSync(artworksDir, { recursive: true });
    if (!fs.existsSync(thumbnailsDir)) fs.mkdirSync(thumbnailsDir, { recursive: true });

    // アルバムアーティストとタイトルから一意なキーを生成
    const uniqueKey = `${albumArtist || 'Unknown Artist'}---${albumTitle || 'Unknown Album'}`;
    const hash = crypto.createHash('sha256').update(uniqueKey).digest('hex');

    const fullFileName = `${hash}.webp`;
    const thumbFileName = `${hash}_thumb.webp`;
    const fullPath = path.join(artworksDir, fullFileName);
    const thumbPath = path.join(thumbnailsDir, thumbFileName);
    try {
        const image = sharp(picture.data);
        // await を使って非同期処理を待つ
        await image.webp({ quality: 80 }).toFile(fullPath);
        await image.resize(100, 100).webp({ quality: 75 }).toFile(thumbPath);
        return { full: fullFileName, thumbnail: thumbFileName };
    } catch (error) {
        console.error(`Failed to save artwork for ${uniqueKey}:`, error);
        return null;
    }
}


function addSongsToLibraryAndSave(newSongs) {
    const library = libraryStore.load() || [];
    const existingPaths = new Set(library.map(s => s.path));
    const uniqueNewSongs = newSongs.filter(s => !existingPaths.has(s.path));
    if (uniqueNewSongs.length > 0) {
        libraryStore.save([...library, ...uniqueNewSongs]);
    }
    return uniqueNewSongs;
}

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
        event.sender.send('loudness-analysis-result', result);
    });

    ipcMain.on('start-scan-paths', async (event, paths) => {
        console.time('Main: Total Import Process');

        const finishScan = (result) => {
            event.sender?.send('scan-complete', result);
            console.timeEnd('Main: Total Import Process');
        };

        const settings = settingsStore.load();
        let libraryPath = settings.libraryPath;

        if (!libraryPath) {
            const result = await dialog.showOpenDialog({
                properties: ['openDirectory'],
                title: 'ライブラリとして使用するフォルダを選択してください'
            });
            if (!result.canceled && result.filePaths.length > 0) {
                libraryPath = result.filePaths[0];
                settings.libraryPath = libraryPath;
                settingsStore.save(settings);
                console.log(`[Import] Library path set to: ${libraryPath}`);
            } else {
                console.error('[Import] Library path selection was canceled.');
                return finishScan([]);
            }
        }

        const sourceFiles = await scanPaths(paths);
        if (sourceFiles.length === 0) {
            console.log('[Import] No new source files found.');
            return finishScan([]);
        }

        const songsWithMetadata = await parseFiles(sourceFiles);
        const existingLibraryPaths = new Set((libraryStore.load() || []).map(s => s.path));

        const songsToProcess = songsWithMetadata.filter(song => {
            const artistDir = sanitize(song.albumartist || song.artist || 'Unknown Artist');
            const albumDir = sanitize(song.album || 'Unknown Album');
            const destPath = path.join(libraryPath, artistDir, albumDir, sanitize(path.basename(song.path)));
            return !existingLibraryPaths.has(destPath);
        });

        if (songsToProcess.length === 0) {
            console.log('[Import] All files are already in the library.');
            return finishScan([]);
        }

        // アルバムごとに曲をグループ化し、代表アートワークを取得
        const albumsToProcess = new Map();
        songsToProcess.forEach(song => {
            // アルバムアーティストが存在すればそれを優先、なければアーティスト名を使う
            const albumArtistKey = song.albumartist || song.artist || 'Unknown Artist';
            const albumKey = `${albumArtistKey}---${song.album || 'Unknown Album'}`; // キー生成を変更

            if (!albumsToProcess.has(albumKey)) {
                albumsToProcess.set(albumKey, {
                    songs: [],
                    artworkPicture: null,
                    albumArtist: albumArtistKey, // 保存しておく
                    albumTitle: song.album || 'Unknown Album' // 保存しておく
                });
            }
            const albumGroup = albumsToProcess.get(albumKey);
            albumGroup.songs.push(song);
            // 既存のアートワークがない場合のみ設定
            if (!albumGroup.artworkPicture && song.artwork) {
                albumGroup.artworkPicture = song.artwork;
            }
        });


        // --- ▼▼▼ アートワーク保存処理を修正 ▼▼▼ ---
        const albumsData = albumsStore.load() || {}; // 既存のアルバムデータをロード
        for (const [key, group] of albumsToProcess.entries()) {
            // アートワークをファイルに保存 (キー情報を渡す)
            const savedArtwork = await saveArtworkToFile(group.artworkPicture, group.albumArtist, group.albumTitle);
            group.songs.forEach(song => {
                song.artwork = savedArtwork; // 保存されたファイル名(フルとサムネイル)を設定
            });
            // 新しいアルバム情報をalbums.json用データに追加 (または更新)
            albumsData[key] = {
                title: group.albumTitle,
                artist: group.albumArtist,
                songs: group.songs.map(s => s.path), // 曲のパスだけ保存するなどに変更も検討
                artwork: savedArtwork
            };
        }
        albumsStore.save(albumsData); // albums.json を保存
        // --- ▲▲▲ ここまで修正 ▲▲▲ ---

        // 曲オブジェクトから埋め込みアートワークデータを削除 (ファイルに保存したので不要)
        songsToProcess.forEach(song => {
            if (song.artwork && typeof song.artwork === 'object' && song.artwork.data) {
                delete song.artwork.data; // Bufferデータを削除
            }
        });

        songsToProcess.forEach(song => { song.originalPath = song.path; });


        const totalSteps = songsToProcess.length;
        let completedSteps = 0;
        const sendProgress = () => event.sender?.send('scan-progress', { current: completedSteps, total: totalSteps });
        sendProgress();

        const importMode = settings.importMode || 'balanced';
        const numCpuCores = os.cpus().length;
        const totalMemoryGB = os.totalmem() / (1024 ** 3);
        let concurrency;

        if (importMode === 'performance') {
            const memoryFactor = Math.floor(totalMemoryGB / 16);
            concurrency = Math.min(numCpuCores * 2, numCpuCores + memoryFactor);
        } else {
            concurrency = os.platform() === 'win32' ? Math.max(1, numCpuCores - 1) : numCpuCores;
        }
        concurrency = Math.max(1, concurrency);

        console.log(`[Import] Starting analysis in ${importMode} mode with ${totalMemoryGB.toFixed(1)}GB RAM. Concurrency set to: ${concurrency}`);

        const newSongObjects = [];
        const loudnessData = loudnessStore.load();

        await new Promise(resolve => {
            let runningWorkers = 0;
            const queue = [...songsToProcess];

            const onWorkerExit = () => {
                runningWorkers--;
                if (queue.length > 0) {
                    startWorker();
                } else if (runningWorkers === 0) {
                    resolve();
                }
            };

            function startWorker() {
                if (runningWorkers >= concurrency || queue.length === 0) return;

                runningWorkers++;
                const songToProcess = queue.shift();

                const worker = new Worker(path.join(__dirname, '..', 'analysis-worker.js'));

                worker.postMessage({
                    type: 'init',
                    ffmpegPath: require('ffmpeg-static').replace('app.asar', 'app.asar.unpacked'),
                    ffprobePath: require('ffprobe-static').path.replace('app.asar', 'app.asar.unpacked')
                });

                Promise.resolve()
                    .then(() => {
                        const artistDir = sanitize(songToProcess.albumartist || songToProcess.artist || 'Unknown Artist');
                        const albumDir = sanitize(songToProcess.album || 'Unknown Album');
                        const destDir = path.join(libraryPath, artistDir, albumDir);
                        if (!fs.existsSync(destDir)) fs.mkdirSync(destDir, { recursive: true });

                        const destPath = path.join(destDir, sanitize(path.basename(songToProcess.path)));
                        if (songToProcess.path !== destPath && !fs.existsSync(destPath)) {
                             fs.copyFileSync(songToProcess.path, destPath);
                        }
                        songToProcess.path = destPath;

                        worker.postMessage({ type: 'analyze', song: songToProcess });
                    })
                    .catch(error => {
                        console.error(`[Import] Failed to process file ${songToProcess.originalPath}:`, error);
                        completedSteps++;
                        sendProgress();
                        worker.terminate();
                    });

                worker.on('message', (result) => {
                    const finalSong = result.song;
                    if (finalSong.loudness) loudnessData[finalSong.path] = finalSong.loudness;
                    delete finalSong.loudness; // library.jsonには保存しない

                    console.log(`[Import] Finished analysis for: ${finalSong.artist} - ${finalSong.title}`);

                    newSongObjects.push(finalSong);
                    completedSteps++;
                    sendProgress();

                    worker.terminate();
                });

                worker.on('exit', onWorkerExit);
                worker.on('error', (err) => {
                    console.error(`[Import] Worker error for ${songToProcess.originalPath}:`, err);
                    completedSteps++;
                    sendProgress();
                    onWorkerExit();
                });
            }

            for (let i = 0; i < concurrency; i++) {
                startWorker();
            }
        });

        const sourceOrderMap = new Map(sourceFiles.map((path, index) => [path, index]));
        newSongObjects.sort((a, b) => {
            const orderA = sourceOrderMap.get(a.originalPath);
            const orderB = sourceOrderMap.get(b.originalPath);
            if (orderA === undefined) return 1;
            if (orderB === undefined) return -1;
            return orderA - orderB;
        });

        newSongObjects.forEach(song => delete song.originalPath); // 元のパス情報は削除

        if (newSongObjects.length > 0) loudnessStore.save(loudnessData);

        const addedSongs = addSongsToLibraryAndSave(newSongObjects);
        finishScan(addedSongs);
    });

    ipcMain.handle('get-loudness-value', (event, songPath) => (loudnessStore.load() || {})[songPath] || null);

    ipcMain.on('request-initial-library', (event) => {
        const songs = libraryStore.load() || [];
        const albums = albumsStore.load() || {}; // albums.json をロード
        event.sender?.send('load-library', { songs, albums }); // albums も送信
    });


    ipcMain.on('debug-reset-library', (event) => {
        try {
            libraryStore.save([]);
            loudnessStore.save({});
            playCountsStore.save({});
            albumsStore.save({}); // albums.json もリセット
            const artworksDir = path.join(app.getPath('userData'), 'Artworks');
            if (fs.existsSync(artworksDir)) fs.rmSync(artworksDir, { recursive: true, force: true });
            const libraryPath = settingsStore.load().libraryPath;
            // ライブラリパス自体は削除せず、中身だけ削除するように変更
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

    // --- ▼▼▼ メタデータ編集ハンドラを追加 ▼▼▼ ---
    ipcMain.handle('edit-metadata', async (event, { filePath, newTags }) => {
        try {
            // 1. node-id3 でファイルに書き込み
            //    - newTags.image が null ならアートワーク削除
            //    - newTags.image が object ならアートワーク更新
            //    - newTags.image が undefined ならアートワーク変更なし
            const tagsToWrite = { ...newTags }; // 元のオブジェクトを変更しないようにコピー
            let artworkResult = undefined; // アートワークの更新結果を保持

            if (tagsToWrite.image === null) {
                // アートワーク削除
                tagsToWrite.image = undefined; // node-id3 に削除を指示
                artworkResult = null; // library.json 更新用に null を設定
            } else if (tagsToWrite.image && tagsToWrite.image.imageBuffer) {
                // アートワーク更新
                // imageBuffer は Buffer である想定
                artworkResult = await saveArtworkToFile({ data: tagsToWrite.image.imageBuffer }, tagsToWrite.artist, tagsToWrite.album);
                // node-id3 に渡すデータからは Buffer を削除 (メモリ節約)
                tagsToWrite.image.imageBuffer = undefined;
                // node-id3 には保存したファイルのパスではなく、Buffer を渡す必要があるかもしれない
                // → saveArtworkToFile から Buffer を返すか、ここで再度読み込む？
                // → node-id3 の write は Buffer を直接受け付けるので、newTags.image をそのまま渡す
                //    ただし、saveArtworkToFile の結果 (ファイル名) は library.json 更新用に必要
            } else {
                 // アートワーク変更なしの場合
                 delete tagsToWrite.image; // image プロパティ自体を削除
            }


            const success = NodeID3.write(tagsToWrite, filePath);

            if (!success) {
                // NodeID3.write が false を返した場合（具体的なエラーは不明）
                 // node-id3 v11以降は例外をスローするようになったため、この分岐は不要になる可能性
                 console.error(`NodeID3.write failed for ${filePath}`);
                 return { success: false, message: 'ファイルへのタグ書き込みに失敗しました。' };
            }

             // 2. library.json の更新
            const library = libraryStore.load() || [];
            const songIndex = library.findIndex(s => s.path === filePath);
            if (songIndex === -1) {
                return { success: false, message: 'ライブラリに対象の曲が見つかりません。' };
            }

            const updatedSong = { ...library[songIndex] };
            updatedSong.title = newTags.title ?? updatedSong.title;
            updatedSong.artist = newTags.artist ?? updatedSong.artist;
            updatedSong.album = newTags.album ?? updatedSong.album;
            updatedSong.genre = newTags.genre ?? updatedSong.genre;
            // artworkResult (saveArtworkToFileの結果) を使ってアートワーク情報を更新
            if (artworkResult !== undefined) { // アートワークに変更があった場合のみ更新
                 updatedSong.artwork = artworkResult;
            }

            // アルバムキーも再計算する必要がある
            const albumArtistKey = updatedSong.albumartist || updatedSong.artist || 'Unknown Artist';
            const albumKey = `${albumArtistKey}---${updatedSong.album || 'Unknown Album'}`;
            updatedSong.albumKey = albumKey; // 更新

            library[songIndex] = updatedSong;
            libraryStore.save(library);

            // 3. albums.json の更新 (該当アルバムのアートワークと曲リスト更新)
            const albumsData = albumsStore.load() || {};
            let albumNeedsUpdate = false;
            // 古いアルバムキーと新しいアルバムキーを取得
            const oldAlbumKey = library[songIndex].albumKey; // 更新前のキーを取るべきだが、ここでは簡単化
            const newAlbumKey = albumKey;

            // TODO: アルバム情報が変わった場合、古いアルバムから曲を削除し、
            // 新しいアルバム（なければ作成）に曲を追加するロジックが必要。
            // アートワークも更新する。
            // ここでは簡易的に、該当アルバムのアートワークだけ更新する
            if (albumsData[newAlbumKey]) {
                if (artworkResult !== undefined) {
                     albumsData[newAlbumKey].artwork = artworkResult;
                     albumNeedsUpdate = true;
                }
                // 必要であれば albumsData[newAlbumKey].songs リストも更新
            } else {
                 // アルバムが新規作成されるケースの処理
                 albumsData[newAlbumKey] = {
                     title: updatedSong.album,
                     artist: albumArtistKey,
                     songs: [updatedSong.path], // とりあえず今の曲だけ追加
                     artwork: artworkResult
                 };
                 albumNeedsUpdate = true;
            }

            if (albumNeedsUpdate) {
                albumsStore.save(albumsData);
            }

            // 4. 成功レスポンス (更新後の曲情報をレンダラーに返す)
            return { success: true, updatedSong: updatedSong };

        } catch (error) {
            console.error(`メタデータ編集エラー (${filePath}):`, error);
            // node-id3 v11以降は例外をスローする
             if (error instanceof Error) {
                 return { success: false, message: `タグ書き込みエラー: ${error.message}` };
             }
             return { success: false, message: '不明なエラーが発生しました。' };
        }
    });
    // --- ▲▲▲ ここまで追加 ▲▲▲ ---
}

module.exports = {
    registerLibraryHandlers,
    saveArtworkToFile
};