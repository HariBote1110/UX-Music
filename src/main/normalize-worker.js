// src/main/normalize-worker.js
const { parentPort } = require('worker_threads');
const fs = require('fs');
const path = require('path');
const ffmpeg = require('fluent-ffmpeg');

let ffmpegPath, ffprobePath;

function initializeFfmpeg() {
    if (ffmpegPath) ffmpeg.setFfmpegPath(ffmpegPath);
    if (ffprobePath) ffmpeg.setFfprobePath(ffprobePath);
}

async function analyzeLoudness(filePath) {
    initializeFfmpeg();
    return new Promise((resolve) => {
        let stderr = '';
        ffmpeg(filePath)
            .withAudioFilter('volumedetect')
            .toFormat('null')
            .on('start', (commandLine) => {
                console.log(`[Analyze Worker] Spawned FFmpeg for ${path.basename(filePath)}: ${commandLine}`);
            })
            .on('error', (err) => resolve({ success: false, error: err.message }))
            .on('stderr', (line) => { stderr += line; })
            .on('end', () => {
                const meanVolumeMatch = stderr.match(/mean_volume:\s*(-?\d+\.\d+)\s*dB/);
                const maxVolumeMatch = stderr.match(/max_volume:\s*(-?\d+\.\d+)\s*dB/);
                
                if (meanVolumeMatch && maxVolumeMatch) {
                    resolve({ 
                        success: true, 
                        loudness: parseFloat(meanVolumeMatch[1]),
                        truePeak: parseFloat(maxVolumeMatch[1])
                    });
                } else {
                    resolve({ success: false, error: 'Could not find mean_volume or max_volume.' });
                }
            })
            .save('-');
    });
}

async function applyNormalization(filePath, gain, backup, outputSettings, basePath) {
    initializeFfmpeg();
    return new Promise((resolve, reject) => {
        const isOverwrite = outputSettings.mode === 'overwrite';
        const originalExt = path.extname(filePath).toLowerCase();

        // 「別のフォルダに保存」モードで、対象がMP4/M4Aの場合のみFLACに変換
        const shouldConvertToFlac = !isOverwrite && ['.mp4', '.m4a'].includes(originalExt);
        
        const outputExt = shouldConvertToFlac ? '.flac' : originalExt;
        const baseName = path.basename(filePath, originalExt);
        const newFileName = baseName + outputExt;

        let outputPath;
        if (isOverwrite) {
            outputPath = filePath;
        } else {
            const relativeDir = (basePath && filePath.startsWith(basePath))
                ? path.dirname(path.relative(basePath, filePath))
                : '';
            outputPath = path.join(outputSettings.path, relativeDir, newFileName);
        }

        const tempPath = outputPath + '.tmp' + outputExt;
        
        fs.mkdirSync(path.dirname(outputPath), { recursive: true });

        if (isOverwrite && backup && !fs.existsSync(filePath + '.bak')) {
            try {
                fs.copyFileSync(filePath, filePath + '.bak');
            } catch (err) {
                return reject(new Error(`Backup creation failed: ${err.message}`));
            }
        }
        
        const command = ffmpeg(filePath)
            .withAudioFilter(`volume=${gain}dB`);

        if (outputExt === '.flac') {
            command.audioCodec('flac');
            if (['.mp4', '.m4a'].includes(originalExt)) {
                // 元ファイルに映像ストリーム(アートワーク)があればコピーする
                command.outputOptions('-c:v', 'copy', '-map', '0:v?', '-map', '0:a');
            }
        } else if (outputExt === '.wav') {
            command.audioCodec('pcm_s16le');
        } else if (outputExt === '.m4a' || outputExt === '.mp4') {
            command.audioCodec('aac').outputOptions('-b:a', '256k', '-vn');
        } else if (outputExt === '.mp3') {
            command.audioCodec('libmp3lame').outputOptions('-q:a', '2', '-vn');
        }
        
        command
            .on('start', (commandLine) => {
                console.log(`[Normalize Worker] Command: ${commandLine}`);
            })
            .on('error', (err) => {
                if (fs.existsSync(tempPath)) { try { fs.unlinkSync(tempPath); } catch (e) {} }
                reject(new Error(`FFmpeg error: ${err.message}`));
            })
            .on('end', () => {
                fs.rename(tempPath, outputPath, (err) => {
                    if (err) { return reject(new Error(`Failed to finalize file: ${err.message}`)); }
                    resolve({ success: true, outputPath });
                });
            })
            .save(tempPath);
    });
}

parentPort.on('message', async (data) => {
    try {
        if (data.type === 'init') {
            ffmpegPath = data.ffmpegPath;
            ffprobePath = data.ffprobePath;
            return;
        }

        // ▼▼▼ 追加: macOSの一時ファイルガード ▼▼▼
        if (data.filePath && (path.basename(data.filePath).startsWith('._') || path.basename(data.filePath) === '.DS_Store')) {
            parentPort.postMessage({
                type: `${data.type}-result`,
                id: data.id,
                result: { success: false, error: 'Ignored macOS system file' }
            });
            return;
        }
        // ▲▲▲ 追加 ▲▲▲

        if (data.type === 'analyze') {
            const result = await analyzeLoudness(data.filePath);
            parentPort.postMessage({ type: 'analysis-result', id: data.id, result });
        } else if (data.type === 'normalize') {
            const result = await applyNormalization(data.filePath, data.gain, data.backup, data.output, data.basePath);
            parentPort.postMessage({ type: 'normalize-result', id: data.id, result });
        }
    } catch (error) {
        const errorMessage = (error instanceof Error) ? error.message : String(error);
        parentPort.postMessage({
            type: `${data.type}-result`,
            id: data.id,
            result: { success: false, error: errorMessage }
        });
    }
});