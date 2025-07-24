const path = require('path');
const fs = require('fs');
const ffmpeg = require('fluent-ffmpeg');
const ffprobePath = require('ffprobe-static').path;
const ffmpegStatic = require('ffmpeg-static'); // まずライブラリを読み込む

// ★★★ ここからが修正箇所です ★★★
// ライブラリが返す値の形式を自動で判別し、正しいパスを取得する
let ffmpegPath;
if (typeof ffmpegStatic === 'string') {
  // 値が単なる文字列の場合（例: '/path/to/ffmpeg'）
  ffmpegPath = ffmpegStatic;
} else if (ffmpegStatic && typeof ffmpegStatic.path === 'string') {
  // 値が.pathプロパティを持つオブジェクトの場合（例: { path: '/path/to/ffmpeg' }）
  ffmpegPath = ffmpegStatic.path;
} else {
  // 予期せぬ形式の場合のエラー処理
  console.error('Could not automatically determine the path for ffmpeg. Please check the ffmpeg-static installation.');
}

// 取得したパスをFFmpegに設定
if (ffmpegPath) {
  ffmpeg.setFfmpegPath(ffmpegPath);
}
ffmpeg.setFfprobePath(ffprobePath);
// ★★★ ここまでが修正箇所です ★★★


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
                // エラーメッセージにffmpegが見つからないという情報が含まれているか確認
                if (err.message.includes('Cannot find ffmpeg')) {
                    resolve({
                        success: false,
                        filePath: filePath,
                        error: 'Cannot find ffmpeg' // エラーメッセージを統一
                    });
                } else {
                    resolve({
                        success: false,
                        filePath: filePath,
                        error: err.message
                    });
                }
            })
            .on('end', (stdout, stderr) => {
                // FFmpegの出力全体から '{' で始まり '}' で終わるブロックを探す
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
                allFiles = allFiles.concat(await scanDirectory(fullPath));
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