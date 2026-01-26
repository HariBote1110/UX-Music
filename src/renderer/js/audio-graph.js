// src/renderer/js/audio-graph.js

import { elements } from './state.js';
const electronAPI = window.electronAPI;

// ▼▼▼ 変更: グラフ（Context+Nodes）のキャッシュ管理 ▼▼▼
const graphCache = new Map(); // key: sampleRate, value: GraphObject
let currentGraph = null;      // 現在アクティブなグラフ

// エクスポート用変数（外部からは常に最新のグラフのノードが見えるようにする）
export let analyser = null;
export let dataArray = null;

let baseGain = 1.0;
let isDirectLinkEnabled = false;
let savedSinkId = 'default'; // 保存されたオーディオ出力デバイスID

/**
 * グラフオブジェクトの構造
 * {
 * sampleRate: number,
 * context: AudioContext,
 * audioElement: HTMLAudioElement,
 * nodes: { source, gain, preamp, eq[], silentGain },
 * directLink: { socket, processor, isConnected }
 * }
 */

/**
 * 指定されたサンプリングレートのオーディオグラフを有効化して返す。
 * キャッシュにあればそれを使い、なければ新規作成する。
 * @param {number} rate - ターゲットサンプリングレート (例: 44100, 48000)
 * @returns {object} GraphObject
 */
export async function activateAudioGraph(rate) {
    // 既存と同じなら何もしない
    if (currentGraph && currentGraph.sampleRate === rate) {
        return currentGraph;
    }

    // 以前のグラフがあれば停止・退避
    if (currentGraph) {
        // Direct Link接続があれば切断（ソケットはSRごとに作り直すため）
        await stopDirectLink(currentGraph);

        // コンテキストを一時停止（CPU負荷軽減）
        if (currentGraph.context.state === 'running') {
            await currentGraph.context.suspend();
        }
    }

    // キャッシュから取得または新規作成
    let graph = graphCache.get(rate);
    if (!graph) {
        console.log(`[AudioGraph] Creating new graph for ${rate}Hz...`);
        graph = await createGraph(rate);
        graphCache.set(rate, graph);
    } else {
        console.log(`[AudioGraph] Resuming cached graph for ${rate}Hz. AudioContext state: ${graph.context.state}`);
    }

    currentGraph = graph;

    // グローバル変数の参照を更新
    analyser = currentGraph.nodes.analyser;
    dataArray = currentGraph.dataArray;

    // コンテキスト再開
    if (currentGraph.context.state === 'suspended') {
        await currentGraph.context.resume();
    }

    // Direct Linkが有効なら接続開始
    if (isDirectLinkEnabled) {
        startDirectLink(currentGraph);
    } else {
        // 通常出力ならスピーカーへ接続
        try {
            currentGraph.nodes.gain.disconnect();
            currentGraph.nodes.gain.connect(currentGraph.context.destination);
            // 保存されたSinkIDを適用
            if (savedSinkId && savedSinkId !== 'default' && typeof currentGraph.context.setSinkId === 'function') {
                currentGraph.context.setSinkId(savedSinkId).catch(e => console.warn('[AudioGraph] Failed to apply saved sinkId:', e));
            }
        } catch (e) { }
    }

    // 音量・EQ設定を適用
    applyMasterVolume();
    // (EQ適用関数は個別に呼ぶ必要があるが、ここではゲインのみ即時適用)

    return currentGraph;
}

/**
 * 新規グラフを作成する
 */
async function createGraph(rate) {
    const AudioContextClass = window.AudioContext || window.webkitAudioContext;
    const context = new AudioContextClass({
        latencyHint: 'playback', // 'interactive' から変更 (プチフリ時のピッチ上昇対策)
        sampleRate: rate
    });

    // 専用のAudio要素を作成
    const audioElement = new Audio();
    // クロスオリジン設定など必要なら記述

    // ノード作成
    const source = context.createMediaElementSource(audioElement);
    const preamp = context.createGain();

    // EQ
    const frequencies = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
    const eqBands = frequencies.map((freq, i) => {
        const filter = context.createBiquadFilter();
        if (i === 0) filter.type = 'lowshelf';
        else if (i === frequencies.length - 1) filter.type = 'highshelf';
        else { filter.type = 'peaking'; filter.Q.value = 1.41; }
        filter.frequency.value = freq;
        filter.gain.value = 0;
        return filter;
    });

    const gain = context.createGain();
    const ana = context.createAnalyser();
    ana.fftSize = 256;
    ana.smoothingTimeConstant = 0.8;
    const dArray = new Uint8Array(ana.frequencyBinCount);

    // 接続
    source.connect(preamp);
    let lastNode = preamp;
    for (const band of eqBands) {
        lastNode.connect(band);
        lastNode = band;
    }
    lastNode.connect(ana);
    ana.connect(gain);

    // デフォルト出力
    gain.connect(context.destination);

    return {
        sampleRate: rate,
        context: context,
        audioElement: audioElement,
        nodes: { source, preamp, eqBands, gain, analyser: ana },
        dataArray: dArray,
        directLink: { socket: null, processor: null, silentGain: null }
    };
}

export async function initAudioGraph(playerElement, sinkId) {
    // 初回初期化またはデバイス変更
    // デバイス変更（SinkID変更）は全キャッシュに対して行う必要があるが、
    // 簡略化のため「次回アクティブになった時」または「現在のグラフ」に適用する

    // sinkIdが渡された場合のみ設定を保存（nullや未定義の場合は保存しない）
    if (sinkId) {
        savedSinkId = sinkId;
        electronAPI.send('save-settings', { audioOutputId: sinkId });
    }

    if (sinkId === 'ux-direct-link') {
        isDirectLinkEnabled = true;
        // グラフのアクティベートは再生時(playLocal)に行われるので、ここではフラグ設定のみでOK
        if (currentGraph) electronAPI.send('direct-link-command', { action: 'start', sampleRate: currentGraph.sampleRate });
    } else {
        isDirectLinkEnabled = false;
        // sinkIdを保持（currentGraphが無くても保持する）
        if (sinkId) {
            savedSinkId = sinkId;
        }
        if (currentGraph) {
            electronAPI.send('direct-link-command', { action: 'stop' });
            // スピーカー出力へ戻す
            try {
                currentGraph.nodes.gain.connect(currentGraph.context.destination);
                // SinkID適用
                const targetSinkId = sinkId || savedSinkId;
                if (typeof currentGraph.context.setSinkId === 'function' && targetSinkId && targetSinkId !== 'default') {
                    currentGraph.context.setSinkId(targetSinkId);
                }
            } catch (e) { }
        }
    }
}

/**
 * 保存されたSinkIDを設定する（起動時の設定復元用）
 */
export function restoreSavedSinkId(sinkId) {
    if (sinkId && sinkId !== 'default') {
        savedSinkId = sinkId;
        console.log('[AudioGraph] Restored saved sinkId:', sinkId);
        // 既にグラフがあれば適用
        if (currentGraph && typeof currentGraph.context.setSinkId === 'function') {
            currentGraph.context.setSinkId(sinkId).catch(e => console.warn('[AudioGraph] Failed to apply restored sinkId:', e));
        }
    }
}

export async function setAudioOutput(deviceId, playerElement) {
    await initAudioGraph(playerElement, deviceId);
}

export async function resumeAudioContext() {
    if (currentGraph && currentGraph.context.state === 'suspended') {
        try { await currentGraph.context.resume(); } catch (e) { }
    }
}

export function setBaseGain(newBaseGain) {
    baseGain = newBaseGain;
    applyMasterVolume();
}

export function applyMasterVolume() {
    if (!currentGraph) return;
    const masterVolume = parseFloat(elements.volumeSlider.value);
    // 現在のグラフに適用
    currentGraph.nodes.gain.gain.setValueAtTime(baseGain * masterVolume, currentGraph.context.currentTime);
}

export function applyEqualizerSettings(settings) {
    // 全キャッシュに適用するのは重いので、現在のグラフにのみ適用し、
    // 他のグラフはアクティブ化された時に適用する設計が理想だが、
    // 今回は簡易的に「現在のグラフ」のみ即時反映する
    if (!currentGraph) return;

    const context = currentGraph.context;
    const preampValue = Math.pow(10, (settings.preamp || 0) / 20);
    currentGraph.nodes.preamp.gain.setValueAtTime(preampValue, context.currentTime);

    for (let i = 0; i < currentGraph.nodes.eqBands.length; i++) {
        if (settings.bands && typeof settings.bands[i] === 'number') {
            currentGraph.nodes.eqBands[i].gain.setValueAtTime(settings.bands[i], context.currentTime);
        }
    }
}

// --- Direct Link Functions ---
// Note: Direct Link requires Node.js net module which is not available in Wails environment.
// These are stub functions to prevent ReferenceError.

function startDirectLink(graph) {
    if (!graph) return;
    console.log('[DirectLink] Direct Link is not available in Wails environment.');
    // Wails環境ではDirect Linkが使用できないため、通常出力に切り替え
    isDirectLinkEnabled = false;
    try {
        graph.nodes.gain.disconnect();
        graph.nodes.gain.connect(graph.context.destination);
    } catch (e) { }
}

async function stopDirectLink(graph) {
    if (!graph) return;
    // スタブ関数 - 何もしない
}
