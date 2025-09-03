const path = require('path');
const fs = require('fs');
const { app } = require('electron');
const MusicTempo = require('music-tempo');
const tmp = require('tmp');
const wavDecoder = require('wav-decoder');

let ffmpeg;

function initializeFfmpeg() {
    if (ffmpeg) return;

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
    initializeFfmpeg();
    return new Promise((resolve) => {
        let stderr = '';
        ffmpeg(filePath)
            .withAudioFilter('volumedetect')
            .toFormat('null')
            .on('error', (err) => resolve({ success: false, filePath, error: err.message }))
            .on('stderr', (line) => { stderr += line; })
            .on('end', () => {
                const match = stderr.match(/mean_volume:\s*(-?\d+\.\d+)\s*dB/);
                if (match && match[1]) {
                    resolve({ success: true, filePath, loudness: parseFloat(match[1]) });
                } else {
                    resolve({ success: false, filePath, error: 'volumedetect: mean_volume not found.' });
                }
            })
            .save('-');
    });
}

// ▼▼▼ ここからが修正箇所です ▼▼▼
/**
 * astatsフィルターを使用して曲のダイナミックレンジから「Energy」スコアを算出します。
 * @param {string} filePath - 解析対象の曲のパス
 * @returns {Promise<number|null>} Energyスコア (0-10) または null
 */
async function analyzeEnergy(filePath) {
    initializeFfmpeg();
    return new Promise((resolve) => {
        let stderr = '';
        ffmpeg(filePath)
            .withAudioFilter('astats')
            .toFormat('null')
            .on('error', (err) => {
                console.error(`[Energy Analysis] FFmpeg error for ${path.basename(filePath)}:`, err.message);
                resolve(null);
            })
            .on('stderr', (line) => { stderr += line; })
            .on('end', () => {
                const peakMatch = stderr.match(/Peak level dB:\s*(-?\d+\.\d+)/);
                const rmsMatch = stderr.match(/RMS level dB:\s*(-?\d+\.\d+)/);

                if (peakMatch && rmsMatch) {
                    const peak = parseFloat(peakMatch[1]);
                    const rms = parseFloat(rmsMatch[1]);
                    const crestFactor = peak - rms; // ピークと平均音量の差（ダイナミックレンジの指標）
                    
                    // Crest Factorを0-10のEnergyスコアに変換
                    // 20dB以上の非常にダイナミックな曲を10とする
                    const energy = Math.min(10, Math.round((crestFactor / 20) * 10));
                    console.log(`[Energy Analysis] ${path.basename(filePath)} -> Crest Factor: ${crestFactor.toFixed(2)}dB, Energy: ${energy}`);
                    resolve(energy);
                } else {
                    console.warn(`[Energy Analysis] Could not find stats for ${path.basename(filePath)}.`);
                    resolve(null);
                }
            })
            .save('-');
    });
}
// ▲▲▲ ここまでが修正箇所です ▲▲▲

async function analyzeBPM(songPath) {
    initializeFfmpeg();
    const tempFile = tmp.fileSync({ postfix: '.wav' });
    try {
        await new Promise((resolve, reject) => {
            ffmpeg(songPath).toFormat('wav').audioChannels(1).audioFrequency(22050)
                .on('error', reject).on('end', resolve).save(tempFile.name);
        });
        const buffer = fs.readFileSync(tempFile.name);
        const audioData = await wavDecoder.decode(buffer);
        const calcTempo = new MusicTempo(audioData.channelData[0]);
        let rawBPM = calcTempo.tempo;
        if (rawBPM > 180) rawBPM /= 2;
        return Math.round(rawBPM);
    } catch (error) {
        console.error(`[BPM Analysis] Failed for ${path.basename(songPath)}:`, error);
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
            const artwork = common.picture?.[0] || null;
            const hasVideo = metadata.format.trackInfo?.some(t => t.type === 'video') || metadata.format.container?.toLowerCase().includes('mp4');

            songs.push({
                path: filePath,
                title: common.title || path.basename(filePath),
                artist: common.artist || 'Unknown Artist',
                albumartist: common.albumartist,
                album: common.album || 'Unknown Album',
                artwork,
                duration: metadata.format.duration,
                year: common.year,
                bpm: common.bpm,
                genre: common.genre?.[0] || null,
                fileSize: stats.size,
                type: 'local',
                hasVideo,
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

module.exports = { scanPaths, parseFiles, analyzeLoudness, analyzeBPM, analyzeEnergy };