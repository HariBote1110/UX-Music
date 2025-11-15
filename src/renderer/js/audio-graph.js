// src/renderer/js/audio-graph.js

import { elements } from './state.js';
const { ipcRenderer } = require('electron');

let audioContext;
let mainPlayerNode; // <video> 要素のソースノード
let gainNode; // マスター音量用
let preampGainNode; // EQプリアンプ用
let eqBands = [];
let baseGain = 1.0; // ラウドネスノーマライゼーション用のゲイン

// Visualizer と Player で共有するノードとデータ
export let analyser;
export let dataArray;

/**
 * AudioContext を（必要なら再作成して）初期化し、ノードを接続する
 * @param {HTMLMediaElement} playerElement - <video> 要素
 * @param {string} sinkId - 出力デバイスID
 */
export async function initAudioGraph(playerElement, sinkId) {
    await createAudioContext(sinkId);
    connectAudioGraph(playerElement);
}

/**
 * AudioContext を非同期で作成（または再作成）する
 * @param {string} sinkId - 出力デバイスID
 */
async function createAudioContext(sinkId = 'default') {
    if (audioContext) {
        if (audioContext.state !== 'closed') {
             try {
                 await audioContext.close();
             } catch (e) {
                 console.error("Error closing previous AudioContext:", e);
             }
        }
    }
    try {
        if (sinkId && sinkId !== 'default' && typeof AudioContext.prototype.setSinkId === 'function') {
             audioContext = new (window.AudioContext || window.webkitAudioContext)();
             try {
                 await audioContext.setSinkId(sinkId);
                 console.log(`AudioContext sinkId set to: ${sinkId}`);
             } catch (err) {
                 console.error(`Failed to set sinkId '${sinkId}', falling back to default. Error:`, err);
                 await audioContext.close();
                 audioContext = new (window.AudioContext || window.webkitAudioContext)();
             }
        } else {
             audioContext = new (window.AudioContext || window.webkitAudioContext)();
             console.log(`AudioContext created with default sinkId.`);
        }
        return audioContext;
    } catch (e) {
        console.error('Failed to create AudioContext:', e);
        try {
            // フォールバック
            audioContext = new (window.AudioContext || window.webkitAudioContext)();
            return audioContext;
        } catch (fallbackError) {
             console.error('Fallback AudioContext creation failed:', fallbackError);
             return null;
        }
    }
}

/**
 * オーディオノードを接続する
 * @param {HTMLMediaElement} playerElement - <video> 要素
 */
function connectAudioGraph(playerElement) {
    if (!audioContext || !playerElement || audioContext.state === 'closed') {
         console.warn("Cannot connect audio graph: AudioContext or player not ready.");
         return;
    }
    try {
        if (mainPlayerNode) {
            try {
                 mainPlayerNode.disconnect();
            } catch (e) {
                 // Ignore error
            }
        }

        mainPlayerNode = audioContext.createMediaElementSource(playerElement);
        preampGainNode = audioContext.createGain();

        const frequencies = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
        eqBands = frequencies.map((freq, i) => {
            const filter = audioContext.createBiquadFilter();
            if (i === 0) filter.type = 'lowshelf';
            else if (i === frequencies.length - 1) filter.type = 'highshelf';
            else { filter.type = 'peaking'; filter.Q.value = 1.41; }
            filter.frequency.value = freq;
            filter.gain.value = 0;
            return filter;
        });

        gainNode = audioContext.createGain(); // マスター音量
        analyser = audioContext.createAnalyser(); // ビジュアライザー用
        analyser.fftSize = 256;
        analyser.smoothingTimeConstant = 0.8;
        analyser.minDecibels = -80;
        analyser.maxDecibels = -10;
        dataArray = new Uint8Array(analyser.frequencyBinCount);

        // 接続順: Source -> Preamp -> EQ -> Analyser -> Gain -> Destination
        mainPlayerNode.connect(preampGainNode);
        let lastNode = preampGainNode;
        for (const band of eqBands) {
            lastNode.connect(band);
            lastNode = band;
        }
        lastNode.connect(analyser);
        analyser.connect(gainNode);
        gainNode.connect(audioContext.destination);

        console.log("Web Audio graph connected successfully.");

    } catch (e) {
        console.error('Failed to connect Web Audio graph:', e);
    }
}

/**
 * AudioContext が一時停止している場合、再開する
 * (visualizer.js と player.js から呼ばれる)
 */
export async function resumeAudioContext() {
    if (audioContext && audioContext.state === 'suspended') {
        try {
            await audioContext.resume();
            console.log("AudioContext resumed.");
        } catch (e) {
            // console.error('Failed to resume AudioContext:', e);
        }
    }
}

/**
 * ラウドネスノーマライゼーション用のベースゲインを設定する
 * @param {number} newBaseGain - 新しいゲイン値 (例: 1.0)
 */
export function setBaseGain(newBaseGain) {
    baseGain = newBaseGain;
    applyMasterVolume(); // すぐに音量に反映
}

/**
 * マスター音量（スライダーの値 * ベースゲイン）を適用する
 */
export function applyMasterVolume() {
    if (!gainNode || !audioContext || audioContext.state === 'closed') return;
    const masterVolume = parseFloat(elements.volumeSlider.value);
    // スライダーの音量とノーマライズゲインを乗算
    gainNode.gain.setValueAtTime(baseGain * masterVolume, audioContext.currentTime);
}

/**
 * イコライザーの設定をオーディオグラフに適用する
 * @param {object} settings - { preamp, bands }
 */
export function applyEqualizerSettings(settings) {
    if (!preampGainNode || eqBands.length === 0 || !audioContext || audioContext.state === 'closed') return;
    
    const preampValue = Math.pow(10, (settings.preamp || 0) / 20);
    preampGainNode.gain.setValueAtTime(preampValue, audioContext.currentTime);
    
    for (let i = 0; i < eqBands.length; i++) {
        if (settings.bands && typeof settings.bands[i] === 'number') {
            eqBands[i].gain.setValueAtTime(settings.bands[i], audioContext.currentTime);
        }
    }
}

/**
 * オーディオ出力デバイスを変更する
 * @param {string} deviceId - 新しいデバイスID
 * @returns {Promise<boolean>} 成功したかどうか
 */
export async function setAudioOutput(deviceId, playerElement) {
    ipcRenderer.send('save-settings', { audioOutputId: deviceId });
    // AudioContext を再作成し、ノードを再接続
    await initAudioGraph(playerElement, deviceId);
}