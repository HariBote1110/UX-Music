// src/main/handlers/cd-rip-handler.js

const { ipcMain, app, shell, net } = require('electron');
const path = require('path');
const fs = require('fs');
const { spawn, exec } = require('child_process');
const { sanitize } = require('../utils');
// 依存関係
const ffmpeg = require('fluent-ffmpeg');
const ffmpegPath = require('ffmpeg-static');

// ffmpegのパスを設定 (Electronビルド環境に対応)
let ffmpegBinary = ffmpegPath;
if (app.isPackaged) {
    ffmpegBinary = ffmpegPath.replace('app.asar', 'app.asar.unpacked');
}
ffmpeg.setFfmpegPath(ffmpegBinary);

function getBinPath(executableName) {
    const isPackaged = app.isPackaged;
    const basePath = isPackaged
        ? path.join(process.resourcesPath, 'bin', 'macos')
        : path.join(__dirname, '../bin/macos');
    
    return path.join(basePath, executableName);
}

const CDPARANOIA_PATH = getBinPath('cdparanoia');

// 共通: MusicBrainz APIへのリクエストヘルパー
function queryMusicBrainz(url) {
    console.log(`[MusicBrainz] Query: ${url}`);
    return new Promise((resolve, reject) => {
        const request = net.request(url);
        request.setHeader('User-Agent', 'UXMusic/0.1.0 ( contact@example.com )');
        
        request.on('response', (response) => {
            let data = '';
            response.on('data', (chunk) => { data += chunk; });
            response.on('end', () => {
                if (response.statusCode === 200) {
                    try {
                        resolve(JSON.parse(data));
                    } catch (e) {
                        reject(new Error('Invalid JSON response'));
                    }
                } else if (response.statusCode === 404) {
                    resolve(null); // 見つからない
                } else {
                    console.warn(`[MusicBrainz] Error: ${response.statusCode}`);
                    resolve(null);
                }
            });
        });
        request.on('error', (err) => reject(err));
        request.end();
    });
}

// Cover Art Archiveから画像を取得 (HTTPSに強制変換)
function getCoverArtUrl(releaseId) {
    return new Promise((resolve) => {
        const url = `https://coverartarchive.org/release/${releaseId}`;
        const request = net.request(url);
        
        request.on('response', (response) => {
            if (response.statusCode === 200) {
                let data = '';
                response.on('data', (chunk) => { data += chunk; });
                response.on('end', () => {
                    try {
                        const json = JSON.parse(data);
                        // front画像を探す (優先: front=true, 次点: images[0])
                        const front = json.images.find(img => img.front) || json.images[0];
                        if (front && front.image) {
                            // http を https に置換して返す
                            resolve(front.image.replace(/^http:/, 'https:'));
                        } else {
                            resolve(null);
                        }
                    } catch (e) {
                        resolve(null);
                    }
                });
            } else {
                resolve(null);
            }
        });
        request.on('error', () => resolve(null));
        request.end();
    });
}

// アートワーク画像を一時ファイルにダウンロードする
function downloadArtworkToTemp(url) {
    if (!url) return Promise.resolve(null);
    return new Promise((resolve) => {
        const tempPath = path.join(app.getPath('temp'), `artwork_${Date.now()}.jpg`);
        const request = net.request(url);
        request.on('response', (response) => {
            if (response.statusCode === 200) {
                const fileStream = fs.createWriteStream(tempPath);
                response.on('data', (chunk) => fileStream.write(chunk));
                response.on('end', () => {
                    fileStream.end();
                    resolve(tempPath);
                });
            } else {
                resolve(null);
            }
        });
        request.on('error', () => resolve(null));
        request.end();
    });
}

function checkDriveStatus() {
    return new Promise((resolve) => {
        exec('drutil status', (error, stdout, stderr) => {
            if (error) return resolve({ hasMedia: false, raw: stderr });
            const lowerOut = stdout.toLowerCase();
            const hasMedia = lowerOut.includes('audio cd') || lowerOut.includes('cd-rom');
            resolve({ hasMedia, raw: stdout });
        });
    });
}

function getTrackList() {
    return new Promise((resolve) => {
        const child = spawn(CDPARANOIA_PATH, ['-Q'], { encoding: 'utf8' });
        let output = '';

        child.stderr.on('data', (data) => { output += data.toString(); });
        child.stdout.on('data', (data) => { output += data.toString(); });

        child.on('close', (code) => {
            if (code !== 0) return resolve([]); 
            
            const tracks = [];
            const lines = output.split('\n');
            const trackRegex = /^\s*(\d+)\.\s+(\d+)/;
            
            lines.forEach(line => {
                const match = line.match(trackRegex);
                if (match) {
                    tracks.push({
                        number: parseInt(match[1]),
                        title: `Track ${match[1]}`,
                        artist: 'Unknown Artist',
                        duration: '', 
                        sectors: parseInt(match[2])
                    });
                }
            });
            resolve(tracks);
        });
    });
}

// TOC検索 (DiscID)
async function searchByTOC(tracks) {
    if (!tracks || tracks.length === 0) return [];

    let currentOffset = 150; 
    const offsets = [];
    tracks.forEach(t => {
        offsets.push(currentOffset);
        currentOffset += t.sectors;
    });
    
    const tocQuery = [1, tracks.length, currentOffset, ...offsets].join('+');
    const url = `https://musicbrainz.org/ws/2/discid/-?toc=${tocQuery}&fmt=json`;
    
    const data = await queryMusicBrainz(url);
    return data && data.releases ? data.releases : [];
}

// テキスト検索
async function searchByText(query) {
    const encodedQuery = encodeURIComponent(query);
    const url = `https://musicbrainz.org/ws/2/release/?query=${encodedQuery}&fmt=json&limit=15`;
    const data = await queryMusicBrainz(url);
    return data && data.releases ? data.releases : [];
}

// リリース詳細取得 (トラックリスト含む)
async function getReleaseDetails(releaseId) {
    const url = `https://musicbrainz.org/ws/2/release/${releaseId}?inc=artist-credits+recordings&fmt=json`;
    return await queryMusicBrainz(url);
}

// リッピングと変換処理 (ffmpeg使用)
async function ripAndConvert(track, outputDir, event, options, tempArtworkPath) {
    const { number, title, artist, album } = track;
    const { format, bitrate } = options;
    
    const safeTitle = sanitize(title) || `Track ${number}`;
    const safeArtist = sanitize(artist) || 'Unknown Artist';
    
    // 一時WAVファイル
    const tempWav = path.join(app.getPath('temp'), `rip_${Date.now()}_track${number}.wav`);
    
    // 出力先ディレクトリ
    const artistDir = path.join(outputDir, safeArtist);
    if (!fs.existsSync(artistDir)) fs.mkdirSync(artistDir, { recursive: true });

    // 拡張子の決定
    let ext = 'm4a';
    if (format === 'flac') ext = 'flac';
    else if (format === 'wav') ext = 'wav';
    else if (format === 'mp3') ext = 'mp3';
    else if (format === 'aac') ext = 'm4a';

    const finalBaseName = `${String(number).padStart(2, '0')} - ${safeTitle}`;
    const finalPath = path.join(artistDir, `${finalBaseName}.${ext}`);
    
    let estimatedSizeBytes = (track.sectors || 0) * 2352 + 44;
    
    try {
        // 1. cdparanoiaでWAVとして吸い出し
        if (event.sender && !event.sender.isDestroyed()) {
        event.sender.send('rip-progress', { status: 'ripping', track: number, percent: 0 });
        }
        await new Promise((resolve, reject) => {
            const ripArgs = ['-w', String(number), tempWav];
            const ripper = spawn(CDPARANOIA_PATH, ripArgs);
            
            const progressInterval = setInterval(() => {
                if (fs.existsSync(tempWav) && estimatedSizeBytes > 0) {
                    try {
                        const stats = fs.statSync(tempWav);
                        let percent = (stats.size / estimatedSizeBytes) * 100;
                        if (percent > 99) percent = 99;
                        if (event.sender && !event.sender.isDestroyed()) {
                        event.sender.send('rip-progress', { status: 'ripping', track: number, percent: percent.toFixed(1) });
                        }
                    } catch (e) {}
                }
            }, 500);

            ripper.on('close', (code) => {
                clearInterval(progressInterval);
                if (code === 0) {
                    if (event.sender && !event.sender.isDestroyed()) { event.sender.send('rip-progress', { status: 'ripping', track: number, percent: 100 }); }
                    resolve();
                } else { reject(new Error(`Ripping failed with code ${code}`)); }
            });
        });

        if (!fs.existsSync(tempWav)) throw new Error('Ripped wav file not found');

        // 2. ffmpegで変換 & メタデータ付与 & アートワーク埋め込み
        if (event.sender && !event.sender.isDestroyed()) {
        event.sender.send('rip-progress', { status: 'encoding', track: number });
        }

        await new Promise((resolve, reject) => {
            let command = ffmpeg(tempWav);

            // メタデータ設定
            const metadata = {
                title: title || `Track ${number}`,
                artist: artist || 'Unknown Artist',
                album: album || 'Unknown Album',
                track: number,
                date: new Date().getFullYear()
            };

            // フォーマットごとの設定
            if (format === 'flac') {
                command.audioCodec('flac');
                command.outputOptions('-compression_level 5'); // 圧縮レベル
            } else if (format === 'alac') {
                command.audioCodec('alac');
            } else if (format === 'wav') {
                command.audioCodec('pcm_s16le'); 
            } else if (format === 'mp3') {
                command.audioCodec('libmp3lame').audioBitrate(bitrate || '320k');
            } else if (format === 'aac') {
                command.audioCodec('aac').audioBitrate(bitrate || '320k');
            }

            // タグの書き込み
            command.outputOptions('-map_metadata', '0', '-id3v2_version', '3');
            Object.keys(metadata).forEach(key => {
                command.outputOptions('-metadata', `${key}=${metadata[key]}`);
            });

            // アートワーク埋め込み (WAV以外で有効)
            if (tempArtworkPath && format !== 'wav') {
                command.input(tempArtworkPath);
                
                // 変更点: -c:v copy を追加して、画像をそのまま（JPEG/PNGとして）埋め込む
                // これにより、H.264動画ストリームとして認識されてしまう問題を防ぎます
                command.outputOptions([
                    '-map', '0:0',
                    '-map', '1:0',
                    '-c:v', 'copy',            // ← 重要: 再エンコードを防止
                    '-disposition:v', 'attached_pic'
                ]);
            }

            command.save(finalPath)
                .on('end', () => resolve())
                .on('error', (err) => reject(err));
        });

        if (fs.existsSync(tempWav)) fs.unlinkSync(tempWav);
        return finalPath;

    } catch (error) {
        if (fs.existsSync(tempWav)) fs.unlinkSync(tempWav);
        throw error;
    }
}

function registerCDRipHandlers(stores) {
    const settingsStore = stores.settingsStore || stores.settings;

    ipcMain.handle('cd-scan', async () => {
        try {
            await checkDriveStatus();
            const tracks = await getTrackList();
            return { success: true, tracks };
        } catch (e) {
            console.error(e);
            return { success: false, error: e.message };
        }
    });

    ipcMain.handle('cd-search-toc', async (event, tracks) => {
        try {
            const releases = await searchByTOC(tracks);
            return { success: true, releases };
        } catch (e) {
            return { success: false, error: e.message };
        }
    });

    ipcMain.handle('cd-search-text', async (event, query) => {
        try {
            const releases = await searchByText(query);
            return { success: true, releases };
        } catch (e) {
            return { success: false, error: e.message };
        }
    });

    ipcMain.handle('cd-apply-metadata', async (event, { tracks, releaseId }) => {
        try {
            const [release, artworkUrl] = await Promise.all([
                getReleaseDetails(releaseId),
                getCoverArtUrl(releaseId)
            ]);

            if (!release || !release.media || !release.media[0].tracks) {
                return { success: false, message: 'Invalid release data' };
            }

            const mbTracks = release.media[0].tracks;
            const albumTitle = release.title;
            const albumArtist = release['artist-credit']?.[0]?.name || 'Unknown Artist';

            const result = tracks.map((t, index) => {
                const mbTrack = mbTracks.find(m => parseInt(m.position) === t.number) || mbTracks[index];

                if (mbTrack) {
                    const trackArtist = mbTrack.recording['artist-credit']?.[0]?.name || albumArtist;
                    return {
                        ...t,
                        title: mbTrack.title,
                        artist: trackArtist,
                        album: albumTitle
                    };
                }
                return t;
            });

            return { 
                success: true, 
                tracks: result, 
                album: albumTitle, 
                artist: albumArtist, 
                artwork: artworkUrl 
            };
        } catch (e) {
            return { success: false, error: e.message };
        }
    });

    ipcMain.on('cd-start-rip', async (event, { tracksToRip, options }) => {
        const settings = settingsStore ? settingsStore.load() : {};
        const libraryPath = settings.libraryPath || app.getPath('music');
        
        const ripOptions = {
            format: options?.format || 'alac',
            bitrate: options?.bitrate || '320k',
            artworkUrl: options?.artworkUrl || null
        };

        const outputDir = path.join(libraryPath, 'CD Rips');
        if (!fs.existsSync(outputDir)) fs.mkdirSync(outputDir, { recursive: true });

        // アートワークを事前にダウンロード (一度だけ)
        let tempArtworkPath = null;
        if (ripOptions.artworkUrl) {
            try {
                tempArtworkPath = await downloadArtworkToTemp(ripOptions.artworkUrl);
            } catch (e) {
                console.error('Artwork download failed:', e);
            }
        }

        for (const track of tracksToRip) {
            try {
                await ripAndConvert(track, outputDir, event, ripOptions, tempArtworkPath);
                if (event.sender && !event.sender.isDestroyed()) {
                event.sender.send('rip-progress', { status: 'completed', track: track.number });
                }
            } catch (err) {
                console.error(err);
                event.sender.send('rip-progress', { status: 'error', track: track.number, error: err.message });
            }
        }
        
        // アートワーク一時ファイルの削除
        if (tempArtworkPath && fs.existsSync(tempArtworkPath)) {
            fs.unlinkSync(tempArtworkPath);
        }

        if (event.sender && !event.sender.isDestroyed()) {
        event.sender.send('rip-complete', { count: tracksToRip.length });
        }
        setTimeout(() => { shell.openPath(outputDir); }, 500);
    });
}

module.exports = { registerCDRipHandlers };