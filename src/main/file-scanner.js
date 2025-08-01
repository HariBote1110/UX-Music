const path = require('path');
const fs = require('fs');
const { app } = require('electron');

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
    initializeFfmpeg();
    return new Promise((resolve) => {
        ffmpeg(filePath)
            .withAudioFilter('loudnorm=I=-23:LRA=7:print_format=json')
            .toFormat('null')
            .on('error', (err) => {
                resolve({ success: false, filePath: filePath, error: err.message });
            })
            .on('end', (stdout, stderr) => {
                const jsonStartIndex = stderr.lastIndexOf('{');
                const jsonEndIndex = stderr.lastIndexOf('}');
                if (jsonStartIndex > -1 && jsonEndIndex > -1) {
                    const jsonString = stderr.substring(jsonStartIndex, jsonEndIndex + 1);
                    try {
                        const stats = JSON.parse(jsonString);
                        const integratedLoudness = parseFloat(stats.input_i);
                        resolve({ success: true, filePath: filePath, loudness: integratedLoudness });
                    } catch (e) {
                        resolve({ success: false, filePath: filePath, error: `ラウドネス解析結果(JSON)のパースに失敗しました。` });
                    }
                } else {
                     resolve({ success: false, filePath: filePath, error: `ラウドネス解析結果(JSON)が見つかりませんでした。` });
                }
            })
            .save('-');
    });
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

            // ▼▼▼ ここからが修正箇所です ▼▼▼
            // コンテナ情報も使って、より確実に映像の有無を判定する
            const hasVideo = 
                (metadata.format.trackInfo && metadata.format.trackInfo.some(track => track.type === 'video')) 
                || (metadata.format.container && metadata.format.container.toLowerCase().includes('mp4'));
            // ▲▲▲ ここまでが修正箇所です ▲▲▲

            songs.push({
                path: filePath,
                title: common.title || path.basename(filePath),
                artist: common.artist || 'Unknown Artist',
                albumartist: common.albumartist,
                album: common.album || 'Unknown Album',
                artwork: artwork,
                duration: metadata.format.duration,
                year: common.year,
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

module.exports = { scanPaths, parseFiles, analyzeLoudness };