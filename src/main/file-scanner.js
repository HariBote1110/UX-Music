const path = require('path');
const fs = require('fs');
const { app } = require('electron');
const MusicTempo = require('music-tempo');
const tmp = require('tmp');
const wavDecoder = require('wav-decoder');

let ffmpeg; // モジュールを保持する変数を定義

function initializeFfmpeg() {
    if (ffmpeg) return; // 既に初期化済みなら何もしない

    ffmpeg = require('fluent-ffmpeg');

    function getCorrectBinaryPath(binaryName) {
        try {
            const binaryModule = require(binaryName);
            let binaryPath = binaryModule?.path || binaryModule;
            if (binaryPath && app.isPackaged) {
                binaryPath = binaryPath.replace('app.asar', 'app.asar.unpacked');
            }
            return binaryPath;
        } catch (error) {
            console.error(`Error getting path for binary ${binaryName}:`, error);
            return null;
        }
    }

    const ffmpegPath = getCorrectBinaryPath('ffmpeg-static');
    const ffprobePath = getCorrectBinaryPath('ffprobe-static');

    if (ffmpegPath) ffmpeg.setFfmpegPath(ffmpegPath);
    if (ffprobePath) ffmpeg.setFfprobePath(ffprobePath);
}

const supportedExtensions = ['.mp3', '.flac', '.wav', '.ogg', '.m4a', '.mp4'];

function analyzeLoudness(filePath) {
    initializeFfmpeg(); // ★ FFmpegの初期化を呼び出し
    return new Promise((resolve) => {
        let stderr = '';
        ffmpeg(filePath)
            .withAudioFilter('volumedetect')
            .toFormat('null')
            .on('error', (err) => {
                resolve({ success: false, filePath: filePath, error: err.message });
            })
            .on('stderr', (line) => {
                stderr += line;
            })
            .on('end', () => {
                const match = stderr.match(/mean_volume:\s*(-?\d+\.\d+)\s*dB/);
                if (match && match[1]) {
                    const meanVolume = parseFloat(match[1]);
                    resolve({ success: true, filePath: filePath, loudness: meanVolume });
                } else {
                    resolve({ success: false, filePath: filePath, error: 'volumedetect: mean_volume not found in FFmpeg output.' });
                }
            })
            .save('-');
    });
}

// ▼▼▼ ここに analyzeBPM 関数を移動 ▼▼▼
async function analyzeBPM(songPath) {
    initializeFfmpeg(); // ★ FFmpegの初期化を呼び出し
    console.log('[BPM Analysis] Executing FINAL version with octave correction...');

    const tempFile = tmp.fileSync({ postfix: '.wav' });

    try {
        await new Promise((resolve, reject) => {
            ffmpeg(songPath)
                .toFormat('wav')
                .audioChannels(1)
                .audioFrequency(22050)
                .on('error', (err) => {
                    console.error(`[BPM Analysis] FFmpeg error for ${path.basename(songPath)}:`, err.message);
                    reject(err);
                })
                .on('end', () => resolve())
                .save(tempFile.name);
        });
        
        const buffer = fs.readFileSync(tempFile.name);
        const audioData = await wavDecoder.decode(buffer); 
        const calcTempo = new MusicTempo(audioData.channelData[0]); 

        let rawBPM = calcTempo.tempo;
        
        if (rawBPM > 180) {
            console.log(`[BPM Analysis] Octave error detected. Correcting ${rawBPM} -> ${rawBPM / 2}`);
            rawBPM = rawBPM / 2;
        }
        
        const roundedBPM = Math.round(rawBPM);

        console.log(`[BPM Analysis] Analysis successful for ${path.basename(songPath)}: ${roundedBPM} BPM`);
        return roundedBPM;

    } catch (error) {
        console.error(`[BPM Analysis] A critical error occurred during analysis for ${path.basename(songPath)}:`, error);
        return null;
    } finally {
        tempFile.removeCallback();
    }
}

async function scanDirectory(dirPath) {
    let files = [];
    const items = await fs.promises.readdir(dirPath, { withFileTypes: true });
    for (const item of items) {
        const fullPath = path.join(dirPath, item.name);
        if (item.isDirectory()) {
            files = files.concat(await scanDirectory(fullPath));
        } else if (supportedExtensions.includes(path.extname(item.name).toLowerCase())) {
            files.push(fullPath);
        }
    }
    return files;
}

async function parseFiles(filePaths) {
    const musicMetadata = (await import('music-metadata')).default;
    
    const songs = [];
    for (const filePath of filePaths) {
        try {
            const stats = fs.statSync(filePath);
            const metadata = await musicMetadata.parseFile(filePath);
            const common = metadata.common;
            const artwork = (common.picture && common.picture.length > 0) ? common.picture[0] : null;

            const hasVideo = 
                (metadata.format.trackInfo && metadata.format.trackInfo.some(track => track.type === 'video')) 
                || (metadata.format.container && metadata.format.container.toLowerCase().includes('mp4'));

            songs.push({
                path: filePath,
                title: common.title || path.basename(filePath),
                artist: common.artist || 'Unknown Artist',
                albumartist: common.albumartist,
                album: common.album || 'Unknown Album',
                artwork: artwork,
                duration: metadata.format.duration,
                year: common.year,
                bpm: common.bpm,
                genre: (common.genre && common.genre.length > 0) ? common.genre[0] : null,
                fileSize: stats.size,
                type: 'local',
                hasVideo: hasVideo,
            });
        } catch (error) {
            console.error(`Error parsing metadata for ${filePath}:`, error.message);
        }
    }
    return songs;
}

async function scanPaths(paths) {
    let allFiles = [];
    for (const p of paths) {
        try {
            const stats = await fs.promises.stat(p);
            if (stats.isDirectory()) {
                allFiles = allFiles.concat(await scanDirectory(p));
            } else if (supportedExtensions.includes(path.extname(p).toLowerCase())) {
                allFiles.push(p);
            }
        } catch (error) {
            console.error(`Cannot access path ${p}:`, error.message);
        }
    }
    return allFiles;
}

// ▼▼▼ analyzeBPM をエクスポートに追加 ▼▼▼
module.exports = { scanPaths, parseFiles, analyzeLoudness, analyzeBPM }