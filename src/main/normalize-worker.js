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
            .on('error', (err) => resolve({ success: false, error: err.message }))
            .on('stderr', (line) => { stderr += line; })
            .on('end', () => {
                const meanVolumeMatch = stderr.match(/mean_volume:\s*(-?\d+\.\d+)\s*dB/);
                if (meanVolumeMatch) {
                    resolve({ success: true, loudness: parseFloat(meanVolumeMatch[1]) });
                } else {
                    resolve({ success: false, error: 'Could not find mean_volume.' });
                }
            })
            .save('-');
    });
}

async function applyNormalization(filePath, gain, backup, outputSettings) {
    initializeFfmpeg();
    return new Promise((resolve, reject) => {
        const isOverwrite = outputSettings.mode === 'overwrite';
        const outputPath = isOverwrite ? filePath : path.join(outputSettings.path, path.basename(filePath));
        const tempPath = outputPath + '.tmp' + path.extname(outputPath);
        
        if (!isOverwrite) {
            try {
                fs.mkdirSync(path.dirname(outputPath), { recursive: true });
            } catch(e) { /* ignore */ }
        } else if (backup) {
            try {
                if (!fs.existsSync(filePath + '.bak')) {
                    fs.copyFileSync(filePath, filePath + '.bak');
                }
            } catch (err) {
                return reject(new Error(`Backup creation failed: ${err.message}`));
            }
        }
        
        ffmpeg(filePath)
            .withAudioFilter(`volume=${gain}dB`)
            .on('error', (err) => {
                if (fs.existsSync(tempPath)) {
                    try {
                        fs.unlinkSync(tempPath);
                    } catch (unlinkErr) {
                        console.error(`Failed to clean up temp file ${tempPath}:`, unlinkErr);
                    }
                }
                reject(new Error(`FFmpeg error: ${err.message}`));
            })
            .on('end', () => {
                fs.rename(tempPath, outputPath, (err) => {
                    if (err) {
                        return reject(new Error(`Failed to replace original file: ${err.message}`));
                    }
                    resolve({ success: true });
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

        if (data.type === 'analyze') {
            const result = await analyzeLoudness(data.filePath);
            parentPort.postMessage({ type: 'analysis-result', id: data.id, result });
        } else if (data.type === 'normalize') {
            await applyNormalization(data.filePath, data.gain, data.backup, data.output);
            parentPort.postMessage({ type: 'normalize-result', id: data.id, result: { success: true } });
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

