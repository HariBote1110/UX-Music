const path = require('path');
const fs = require('fs');
const ffmpeg = require('fluent-ffmpeg');
const ffprobePath = require('ffprobe-static').path;
// ★★★ ここからが修正箇所です ★★★
// require('ffmpeg-static')から、実行ファイルのパスを示す .path を取得します
const ffmpegPath = require('ffmpeg-static').path;

// ffmpegのパスを正しく設定します
ffmpeg.setFfmpegPath(ffmpegPath);
// ★★★ ここまでが修正箇所です ★★★

// ffprobeのパスは元々正しく設定されていました
ffmpeg.setFfprobePath(ffprobePath);


function sanitize(name) {
    if (typeof name !== 'string') return '_';
    let sanitizedName = name.replace(/[\\/:*?"<>|]/g, '_');
    sanitizedName = sanitizedName.replace(/[. ]+$/, '');
    return sanitizedName || '_';
}

const supportedExtensions = ['.mp3', '.flac', '.wav', '.ogg', '.m4a', '.mp4'];

/**
 * 指定されたオーディオファイルのラウドネス値を解析します。
 * @param {string} filePath 解析するファイルのパス
 * @returns {Promise<object>} 解析結果を含むオブジェクトのPromise
 */
function analyzeLoudness(filePath) {
    return new Promise((resolve) => {
        ffmpeg(filePath)
            .withAudioFilter('loudnorm=I=-23:LRA=7:print_format=json')
            .toFormat('null')
            .on('error', (err) => {
                // ENOENTエラーを防ぐため、エラーメッセージにffmpegのパスを含める
                if (err.message.includes('ENOENT')) {
                     console.error(`ffmpegの実行に失敗しました。パスを確認してください: ${ffmpegPath}`);
                }
                resolve({
                    success: false,
                    filePath: filePath,
                    error: err.message
                });
            })
            .on('end', (stdout, stderr) => {
                const jsonStartIndex = stderr.lastIndexOf('{');
                const jsonEndIndex = stderr.lastIndexOf('}');

                if (jsonStartIndex > -1 && jsonEndIndex > -1) {
                    const jsonString = stderr.substring(jsonStartIndex, jsonEndIndex + 1);
                    try {
                        const stats = JSON.parse(jsonString);
                        const integratedLoudness = parseFloat(stats.input_i);
                        resolve({
                            success: true,
                            filePath: filePath,
                            loudness: integratedLoudness
                        });
                    } catch (e) {
                        resolve({ success: false, filePath: filePath, error: `ラウドネス解析結果(JSON)のパースに失敗しました。` });
                    }
                } else {
                     resolve({
                         success: false,
                         filePath: filePath,
                         error: `ラウドネス解析結果(JSON)が見つかりませんでした。\nFFmpeg Raw Output:\n${stderr}`
                     });
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
    const musicMetadata = await import('music-metadata');
    
    const songs = [];
    for (const filePath of filePaths) {
        try {
            const stats = fs.statSync(filePath);
            const metadata = await musicMetadata.parseFile(filePath);
            const common = metadata.common;
            let artwork = null;
            if (common.picture && common.picture.length > 0) {
                const pic = common.picture[0];
                if (pic.format) { 
                    artwork = `data:${pic.format};base64,${pic.data.toString('base64')}`;
                }
            }
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
                type: 'local'
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

module.exports = { scanPaths, parseFiles, sanitize, analyzeLoudness };