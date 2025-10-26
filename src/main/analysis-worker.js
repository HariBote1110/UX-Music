// analysis-worker.js
// このスクリプトはUIとは別のバックグラウンドスレッドで実行されます。

const { parentPort } = require('worker_threads');
const path = require('path');
const fs = require('fs');
const ffmpeg = require('fluent-ffmpeg');
const MusicTempo = require('music-tempo');
const tmp = require('tmp');
const wavDecoder = require('wav-decoder');

// メインスレッドからFFmpegのパスを受け取る
let ffmpegPath, ffprobePath;

function initializeFfmpeg() {
    if (ffmpegPath) ffmpeg.setFfmpegPath(ffmpegPath);
    if (ffprobePath) ffmpeg.setFfprobePath(ffprobePath);
}

// 各解析関数（file-scanner.jsから移動）
function analyzeLoudness(filePath) {
     console.log(`[Import Debug Worker] Analyzing loudness for: ${filePath}`);
    initializeFfmpeg();
    return new Promise((resolve) => {
        let stderr = '';
        ffmpeg(filePath).withAudioFilter('volumedetect').toFormat('null')
            .on('error', (err) => {
                 console.error(`[Import Debug Worker] Loudness error for ${filePath}: ${err.message}`);
                 resolve({ success: false, error: err.message });
            })
            .on('stderr', (line) => { stderr += line; })
            .on('end', () => {
                const match = stderr.match(/mean_volume:\s*(-?\d+\.\d+)\s*dB/);
                 console.log(`[Import Debug Worker] Loudness stderr for ${path.basename(filePath)}:\n${stderr}`);
                 if (match) {
                     const loudnessValue = parseFloat(match[1]);
                     console.log(`[Import Debug Worker] Loudness found for ${path.basename(filePath)}: ${loudnessValue}`);
                     resolve({ success: !!match, loudness: loudnessValue });
                 } else {
                      console.warn(`[Import Debug Worker] Loudness not found in stderr for ${path.basename(filePath)}.`);
                      resolve({ success: false, error: 'mean_volume not found in ffmpeg output.' });
                 }
            })
            .save('-');
    });
}

async function analyzeEnergy(filePath) {
     console.log(`[Import Debug Worker] Analyzing energy for: ${filePath}`);
    initializeFfmpeg();
    return new Promise((resolve) => {
        let stderr = '';
        ffmpeg(filePath).withAudioFilter('astats').toFormat('null')
            .on('error', (err) => {
                 console.error(`[Import Debug Worker] Energy error for ${filePath}: ${err.message}`);
                 resolve(null); // Return null on error
            })
            .on('stderr', (line) => { stderr += line; })
            .on('end', () => {
                // console.log(`[Import Debug Worker] Energy stderr for ${path.basename(filePath)}:\n${stderr}`);
                const peakMatch = stderr.match(/Peak level dB:\s*(-?\d+\.\d+)/);
                const rmsMatch = stderr.match(/RMS level dB:\s*(-?\d+\.\d+)/);
                if (peakMatch && rmsMatch) {
                    const crestFactor = parseFloat(peakMatch[1]) - parseFloat(rmsMatch[1]);
                    const energyValue = Math.min(10, Math.round((crestFactor / 20) * 10));
                     console.log(`[Import Debug Worker] Energy calculated for ${path.basename(filePath)}: ${energyValue} (Crest: ${crestFactor.toFixed(2)})`);
                    resolve(energyValue);
                } else {
                     console.warn(`[Import Debug Worker] Energy stats not found in stderr for ${path.basename(filePath)}.`);
                    resolve(null); // Return null if stats not found
                }
            })
            .save('-');
    });
}

async function analyzeBPM(filePath) {
     console.log(`[Import Debug Worker] Analyzing BPM for: ${filePath}`);
    initializeFfmpeg();
    const tempFile = tmp.fileSync({ postfix: '.wav' });
    try {
        await new Promise((resolve, reject) => {
             const command = ffmpeg(filePath)
                 .inputOptions(['-analyzeduration', '10M', '-probesize', '10M']);

             if (path.extname(filePath).toLowerCase() === '.flac') {
                 command.inputFormat('flac');
             }

             command.toFormat('wav')
                 .audioChannels(1)
                 .audioFrequency(22050)
                 .outputOptions('-map', '0:a')
                 .on('error', (err, stdout, stderr) => {
                     const detailedError = new Error(`FFmpeg error during BPM analysis: ${err.message}\n\nFFmpeg stdout:\n${stdout}\n\nFFmpeg stderr:\n${stderr}`);
                     console.error(`[Import Debug Worker] BPM ffmpeg error for ${filePath}:`, detailedError);
                     reject(detailedError);
                 })
                 .on('end', resolve)
                 .save(tempFile.name);
        });
        const buffer = fs.readFileSync(tempFile.name);
        const audioData = await wavDecoder.decode(buffer);
        const calcTempo = new MusicTempo(audioData.channelData[0]);
        let rawBPM = calcTempo.tempo;
        if (rawBPM > 180) rawBPM /= 2;
        const bpmValue = Math.round(rawBPM);
         console.log(`[Import Debug Worker] BPM calculated for ${path.basename(filePath)}: ${bpmValue}`);
        return bpmValue;
    } catch (error) {
        // Error already logged in the promise reject handler
        return null; // Return null on error
    } finally {
        tempFile.removeCallback();
    }
}

// メインスレッドからのメッセージ受信
parentPort.on('message', async (data) => {
     console.log('[Import Debug Worker] Received message:', data.type, data.song?.title);
    if (data.type === 'init') {
        ffmpegPath = data.ffmpegPath;
        ffprobePath = data.ffprobePath;
        return;
    }

    if (data.type === 'analyze') {
        const { song } = data;
        if (!song || !song.path) {
             console.error('[Import Debug Worker] Received invalid song object:', song);
             // Optionally send an error back? For now, just exit.
             return;
        }
        
        // Run analyses sequentially for clearer logging and potential error isolation
        try {
            const loudnessResult = await analyzeLoudness(song.path);
            if (loudnessResult.success) {
                song.loudness = loudnessResult.loudness;
            } else {
                 console.warn(`[Import Debug Worker] Loudness analysis failed for ${song.title}: ${loudnessResult.error}`);
            }
        } catch (e) {
            console.error(`[Import Debug Worker] Unexpected error during loudness analysis for ${song.title}:`, e);
        }

        try {
            // Only analyze BPM if not already present
            if (typeof song.bpm !== 'number' || isNaN(song.bpm)) {
                song.bpm = await analyzeBPM(song.path);
            } else {
                 console.log(`[Import Debug Worker] Skipping BPM analysis for ${song.title} (already present: ${song.bpm})`);
            }
        } catch (e) {
            console.error(`[Import Debug Worker] Unexpected error during BPM analysis for ${song.title}:`, e);
            song.bpm = null; // Ensure it's null if analysis fails unexpectedly
        }

        try {
            song.energy = await analyzeEnergy(song.path);
        } catch (e) {
            console.error(`[Import Debug Worker] Unexpected error during energy analysis for ${song.title}:`, e);
            song.energy = null; // Ensure it's null
        }
        
        console.log(`[Import Debug Worker] Analysis complete for ${song.title}. Sending result back.`);
        // console.log('[Import Debug Worker] Final song object being sent:', song); // Log full object if needed
        // 解析結果をメインスレッドに送り返す
        parentPort.postMessage({ type: 'result', song });
    }
});