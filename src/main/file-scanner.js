const path = require('path');
const fs = require('fs');
const ffmpeg = require('fluent-ffmpeg');
const { app } = require('electron'); // Electronのappモジュールをインポート

// ★★★ ここからが修正箇所です ★★★
/**
 * 開発環境とビルド後の両方で、外部バイナリの正しいパスを取得する、より堅牢な関数。
 * @param {string} binaryName 'ffmpeg-static' または 'ffprobe-static'
 * @returns {string|null} 実行ファイルの絶対パス、または見つからない場合はnull
 */
function getCorrectBinaryPath(binaryName) {
  try {
    const binaryModule = require(binaryName);
    let binaryPath = null;

    // require()が返す値の形式をチェック
    if (typeof binaryModule === 'string') {
      // パターン1: モジュール自体がパス文字列の場合
      binaryPath = binaryModule;
    } else if (binaryModule && typeof binaryModule.path === 'string') {
      // パターン2: モジュールが .path プロパティを持つオブジェクトの場合
      binaryPath = binaryModule.path;
    } else {
      console.error(`Could not determine path for ${binaryName}. Unexpected module format.`);
      return null;
    }
    
    // アプリがパッケージ化されている場合、asar用のパスに修正する
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

if (ffmpegPath) {
  ffmpeg.setFfmpegPath(ffmpegPath);
}
if (ffprobePath) {
  ffmpeg.setFfprobePath(ffprobePath);
}
// ★★★ ここまでが修正箇所です ★★★


function sanitize(name) {
    if (typeof name !== 'string') return '_';
    let sanitizedName = name.replace(/[\\/:*?"<>|]/g, '_');
    sanitizedName = sanitizedName.replace(/[. ]+$/, '');
    return sanitizedName || '_';
}

const supportedExtensions = ['.mp3', '.flac', '.wav', '.ogg', '.m4a', '.mp4'];

function analyzeLoudness(filePath) {
    return new Promise((resolve) => {
        ffmpeg(filePath)
            .withAudioFilter('loudnorm=I=-23:LRA=7:print_format=json')
            .toFormat('null')
            .on('error', (err) => {
                if (err.message.includes('Cannot find ffmpeg')) {
                    resolve({
                        success: false,
                        filePath: filePath,
                        error: 'Cannot find ffmpeg'
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