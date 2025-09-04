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
    initializeFfmpeg();
    return new Promise((resolve) => {
        let stderr = '';
        ffmpeg(filePath).withAudioFilter('volumedetect').toFormat('null')
            .on('error', (err) => resolve({ success: false, error: err.message }))
            .on('stderr', (line) => { stderr += line; })
            .on('end', () => {
                const match = stderr.match(/mean_volume:\s*(-?\d+\.\d+)\s*dB/);
                resolve({ success: !!match, loudness: match ? parseFloat(match[1]) : null });
            })
            .save('-');
    });
}

async function analyzeEnergy(filePath) {
    initializeFfmpeg();
    return new Promise((resolve) => {
        let stderr = '';
        ffmpeg(filePath).withAudioFilter('astats').toFormat('null')
            .on('error', (err) => resolve(null))
            .on('stderr', (line) => { stderr += line; })
            .on('end', () => {
                const peakMatch = stderr.match(/Peak level dB:\s*(-?\d+\.\d+)/);
                const rmsMatch = stderr.match(/RMS level dB:\s*(-?\d+\.\d+)/);
                if (peakMatch && rmsMatch) {
                    const crestFactor = parseFloat(peakMatch[1]) - parseFloat(rmsMatch[1]);
                    resolve(Math.min(10, Math.round((crestFactor / 20) * 10)));
                } else {
                    resolve(null);
                }
            })
            .save('-');
    });
}

async function analyzeBPM(filePath) {
    initializeFfmpeg();
    const tempFile = tmp.fileSync({ postfix: '.wav' });
    try {
        await new Promise((resolve, reject) => {
            ffmpeg(filePath).toFormat('wav').audioChannels(1).audioFrequency(22050)
                .on('error', reject).on('end', resolve).save(tempFile.name);
        });
        const buffer = fs.readFileSync(tempFile.name);
        const audioData = await wavDecoder.decode(buffer);
        const calcTempo = new MusicTempo(audioData.channelData[0]);
        let rawBPM = calcTempo.tempo;
        if (rawBPM > 180) rawBPM /= 2;
        return Math.round(rawBPM);
    } catch (error) {
        return null;
    } finally {
        tempFile.removeCallback();
    }
}

// メインスレッドからのメッセージ受信
parentPort.on('message', async (data) => {
    if (data.type === 'init') {
        ffmpegPath = data.ffmpegPath;
        ffprobePath = data.ffprobePath;
        return;
    }

    if (data.type === 'analyze') {
        const { song } = data;
        
        const loudnessResult = await analyzeLoudness(song.path);
        if (loudnessResult.success) {
            song.loudness = loudnessResult.loudness;
        }

        if (typeof song.bpm !== 'number') {
            song.bpm = await analyzeBPM(song.path);
        }
        song.energy = await analyzeEnergy(song.path);
        
        // 解析結果をメインスレッドに送り返す
        parentPort.postMessage({ type: 'result', song });
    }
});