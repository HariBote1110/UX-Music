// src/main/handlers/cd-rip-handler.js

const { ipcMain, app, shell, net } = require('electron');
const path = require('path');
const fs = require('fs');
const { spawn, exec } = require('child_process');
const { sanitize } = require('../utils');

function getBinPath(executableName) {
    const isPackaged = app.isPackaged;
    const basePath = isPackaged
        ? path.join(process.resourcesPath, 'bin', 'macos')
        : path.join(__dirname, '../bin/macos');
    
    return path.join(basePath, executableName);
}

const XLD_PATH = getBinPath('xld');
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
                        duration: '', // 表示用フォーマットはフロントで計算してもよいが、ここでは省略
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
    // release検索: アーティスト名やアルバム名で検索
    const url = `https://musicbrainz.org/ws/2/release/?query=${encodedQuery}&fmt=json&limit=15`;
    
    const data = await queryMusicBrainz(url);
    return data && data.releases ? data.releases : [];
}

// リリース詳細取得 (トラックリスト含む)
async function getReleaseDetails(releaseId) {
    const url = `https://musicbrainz.org/ws/2/release/${releaseId}?inc=artist-credits+recordings&fmt=json`;
    return await queryMusicBrainz(url);
}

// リッピング処理 (変更なし、省略)
async function ripAndConvert(track, outputDir, event, mode) {
    // ... 前回のコードと同じ実装 ...
    // (スペース節約のため省略しますが、以前の実装をそのまま使います)
    // 実際に動作させる際は前回の ripAndConvert の中身をここに貼り付けてください
    const { number, title, artist } = track;
    const safeTitle = sanitize(title) || `Track ${number}`;
    const safeArtist = sanitize(artist) || 'Unknown Artist';
    
    const tempWav = path.join(app.getPath('temp'), `rip_${Date.now()}_track${number}.wav`);
    const finalBaseName = `${String(number).padStart(2, '0')} - ${safeTitle}`;
    const tempWavNamed = path.join(app.getPath('temp'), `${finalBaseName}.wav`);
    const artistDir = path.join(outputDir, safeArtist);
    if (!fs.existsSync(artistDir)) fs.mkdirSync(artistDir, { recursive: true });
    const finalPath = path.join(artistDir, `${finalBaseName}.m4a`);
    let estimatedSizeBytes = (track.sectors || 0) * 2352 + 44;
    
    try {
        event.sender.send('rip-progress', { status: 'ripping', track: number, percent: 0 });
        await new Promise((resolve, reject) => {
            const ripArgs = [];
            if (mode === 'burst') ripArgs.push('-Z');
            ripArgs.push('-w', String(number), tempWav);
            const ripper = spawn(CDPARANOIA_PATH, ripArgs);
            const progressInterval = setInterval(() => {
                if (fs.existsSync(tempWav) && estimatedSizeBytes > 0) {
                    try {
                        const stats = fs.statSync(tempWav);
                        let percent = (stats.size / estimatedSizeBytes) * 100;
                        if (percent > 99) percent = 99;
                        event.sender.send('rip-progress', { status: 'ripping', track: number, percent: percent.toFixed(1) });
                    } catch (e) {}
                }
            }, 500);
            ripper.stderr.on('data', (data) => {
                const log = data.toString();
                const sectorMatch = log.match(/to sector\s+(\d+)/);
                if (sectorMatch) estimatedSizeBytes = parseInt(sectorMatch[1]) * 2352 + 44;
            });
            ripper.on('close', (code) => {
                clearInterval(progressInterval);
                if (code === 0) {
                    event.sender.send('rip-progress', { status: 'ripping', track: number, percent: 100 });
                    resolve();
                } else { reject(new Error(`Ripping failed with code ${code}`)); }
            });
        });
        if (fs.existsSync(tempWav)) fs.renameSync(tempWav, tempWavNamed);
        else throw new Error('Ripped wav file not found');
        event.sender.send('rip-progress', { status: 'encoding', track: number });
        await new Promise((resolve, reject) => {
            const args = ['-f', 'alac', '-o', artistDir, tempWavNamed];
            const encoder = spawn(XLD_PATH, args);
            encoder.on('close', (code) => {
                if (code === 0) resolve(); else reject(new Error(`Encoding failed with code ${code}`));
            });
        });
        if (fs.existsSync(tempWavNamed)) fs.unlinkSync(tempWavNamed);
        return finalPath;
    } catch (error) {
        if (fs.existsSync(tempWav)) fs.unlinkSync(tempWav);
        if (fs.existsSync(tempWavNamed)) fs.unlinkSync(tempWavNamed);
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

    // ▼▼▼ 1. TOC検索 (候補リストを返す) ▼▼▼
    ipcMain.handle('cd-search-toc', async (event, tracks) => {
        try {
            const releases = await searchByTOC(tracks);
            return { success: true, releases };
        } catch (e) {
            return { success: false, error: e.message };
        }
    });

    // ▼▼▼ 2. テキスト検索 (候補リストを返す) ▼▼▼
    ipcMain.handle('cd-search-text', async (event, query) => {
        try {
            const releases = await searchByText(query);
            return { success: true, releases };
        } catch (e) {
            return { success: false, error: e.message };
        }
    });

    // ▼▼▼ 3. 詳細適用 (選択されたリリースIDからトラック情報を取得) ▼▼▼
    ipcMain.handle('cd-apply-metadata', async (event, { tracks, releaseId }) => {
        try {
            const release = await getReleaseDetails(releaseId);
            if (!release || !release.media || !release.media[0].tracks) {
                return { success: false, message: 'Invalid release data' };
            }

            const mbTracks = release.media[0].tracks;
            const albumTitle = release.title;
            const albumArtist = release['artist-credit']?.[0]?.name || 'Unknown Artist';

            // トラック情報をマージ
            const result = tracks.map((t, index) => {
                // トラック番号が一致するものを探す (通常はindex順だが念のため)
                // MusicBrainzは position プロパティを持つ
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

            return { success: true, tracks: result, album: albumTitle, artist: albumArtist };
        } catch (e) {
            return { success: false, error: e.message };
        }
    });

    ipcMain.on('cd-start-rip', async (event, { tracksToRip }) => {
        const settings = settingsStore ? settingsStore.load() : {};
        const libraryPath = settings.libraryPath || app.getPath('music');
        const ripMode = settings.cdRipMode || 'paranoia';

        const outputDir = path.join(libraryPath, 'CD Rips');
        if (!fs.existsSync(outputDir)) fs.mkdirSync(outputDir, { recursive: true });

        for (const track of tracksToRip) {
            try {
                await ripAndConvert(track, outputDir, event, ripMode);
                event.sender.send('rip-progress', { status: 'completed', track: track.number });
            } catch (err) {
                event.sender.send('rip-progress', { status: 'error', track: track.number, error: err.message });
            }
        }
        event.sender.send('rip-complete', { count: tracksToRip.length });
        setTimeout(() => { shell.openPath(outputDir); }, 500);
    });
}

module.exports = { registerCDRipHandlers };