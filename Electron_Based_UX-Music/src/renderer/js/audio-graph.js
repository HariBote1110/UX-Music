// src/renderer/js/audio-graph.js

import { elements } from './state.js';
const { ipcRenderer } = require('electron');
const net = require('net');
const os = require('os');

// ▼▼▼ 変更: グラフ（Context+Nodes）のキャッシュ管理 ▼▼▼
const graphCache = new Map(); // key: sampleRate, value: GraphObject
let currentGraph = null;      // 現在アクティブなグラフ

// エクスポート用変数（外部からは常に最新のグラフのノードが見えるようにする）
export let analyser = null;
export let dataArray = null;

let baseGain = 1.0;
let isDirectLinkEnabled = false;
let lastEqualizerSettings = null;
const PIPE_NAME = os.platform() === 'win32' ? '\\\\.\\pipe\\ux_audio_router_pipe' : '/tmp/ux_audio_router.sock';

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
        console.log(`[AudioGraph] Resuming cached graph for ${rate}Hz.`);
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
        } catch(e) {}
    }

    // 音量・EQ設定を適用
    applyMasterVolume();
    if (lastEqualizerSettings) applyEqualizerSettings(lastEqualizerSettings);

    return currentGraph;
}

/**
 * 新規グラフを作成する
 */
async function createGraph(rate) {
    const AudioContextClass = window.AudioContext || window.webkitAudioContext;
    const context = new AudioContextClass({
        latencyHint: 'interactive',
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
    
    ipcRenderer.send('save-settings', { audioOutputId: sinkId });
    
    if (sinkId === 'ux-direct-link') {
        isDirectLinkEnabled = true;
        // グラフのアクティベートは再生時(playLocal)に行われるので、ここではフラグ設定のみでOK
        if (currentGraph) startDirectLink(currentGraph);
    } else {
        isDirectLinkEnabled = false;
        if (currentGraph) {
            stopDirectLink(currentGraph);
            // スピーカー出力へ戻す
            try {
                currentGraph.nodes.gain.connect(currentGraph.context.destination);
                // SinkID適用
                if (typeof currentGraph.context.setSinkId === 'function' && sinkId !== 'default') {
                    currentGraph.context.setSinkId(sinkId);
                }
            } catch(e) {}
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
    lastEqualizerSettings = settings;
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

function startDirectLink(graph) {
    if (!graph || graph.directLink.socket) return; // 既に接続済みなら無視

    console.log(`[DirectLink] Connecting (${graph.sampleRate}Hz)...`);

    try {
        const socket = net.connect(PIPE_NAME, () => {
            console.log(`[DirectLink] Connected (${graph.sampleRate}Hz)`);
            const header = Buffer.alloc(8);
            header.write('UXD1', 0); 
            header.writeUInt32LE(graph.sampleRate, 4);
            socket.write(header);
        });
        
        socket.setNoDelay(true);
        socket.on('error', (err) => {
            console.error('[DirectLink] Error:', err.message);
            stopDirectLink(graph);
        });
        socket.on('close', () => {
            console.log('[DirectLink] Closed.');
            stopDirectLink(graph);
        });

        // 既存出力のミュート
        try { graph.nodes.gain.disconnect(graph.context.destination); } catch(e){}

        // ScriptProcessor作成
        // ノード再利用はトラブルの元なので毎回作成
        const processor = graph.context.createScriptProcessor(4096, 2, 2);
        processor.onaudioprocess = (e) => {
            if (!socket || socket.destroyed) return;
            const left = e.inputBuffer.getChannelData(0);
            const right = e.inputBuffer.getChannelData(1);
            const interleaved = new Float32Array(left.length + right.length);
            for (let i = 0; i < left.length; i++) {
                interleaved[i * 2] = left[i];
                interleaved[i * 2 + 1] = right[i];
            }
            try { socket.write(Buffer.from(interleaved.buffer)); } catch (err) {}
        };

        // サイレントゲイン（プロセス駆動用）
        let silent = graph.directLink.silentGain;
        if (!silent) {
            silent = graph.context.createGain();
            silent.gain.value = 0;
            silent.connect(graph.context.destination);
            graph.directLink.silentGain = silent;
        }

        // 接続
        graph.nodes.analyser.connect(processor);
        processor.connect(silent);

        graph.directLink.socket = socket;
        graph.directLink.processor = processor;

    } catch (e) {
        console.error('[DirectLink] Start failed:', e);
    }
}

function stopDirectLink(graph) {
    if (!graph) return;
    const dl = graph.directLink;

    if (dl.socket) {
        dl.socket.destroy();
        dl.socket = null;
    }
    if (dl.processor) {
        try {
            dl.processor.disconnect();
            graph.nodes.analyser.disconnect(dl.processor);
        } catch(e){}
        dl.processor = null;
    }
    // silentGainは維持してても良いが、切っておく
    if (dl.silentGain) {
        // 再利用のため保持しておくか、破棄するか。ここでは保持。
    }
}