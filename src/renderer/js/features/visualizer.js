// src/renderer/js/visualizer.js

import { elements, state } from '../core/state.js';
import { analyser, dataArray, resumeAudioContext } from './audio-graph.js';
import { isPlaying } from './player.js';

let visualizerFrameId = null;
let currentVisualizerBars = null;
let observedTarget = null;
let lastHeights = new Array(6).fill(4);
let lastFrameTime = 0;
let visualizerObserver = null;
let isVisualizerVisible = false;
let isEcoModeEnabled = true;
const GO_VISUALIZER_FETCH_INTERVAL_MS = 80;

/**
 * ビジュアライザーの描画ループを開始する
 */
export function startVisualizerLoop() {
    lastHeights.fill(4);

    if (!visualizerFrameId && isPlaying()) {
        visualizerFrameId = requestAnimationFrame(draw);
    }
}

/**
 * ビジュアライザーの描画ループを停止する
 */
export function stopVisualizerLoop() {
    if (visualizerFrameId) {
        cancelAnimationFrame(visualizerFrameId);
        visualizerFrameId = null;
    }
    if (currentVisualizerBars) {
        lastHeights.fill(4);
        currentVisualizerBars.forEach(bar => {
            if (bar.style.height !== '4px') bar.style.height = '4px';
        });
    }
}

/**
 * ビジュアライザーのエコモード（IntersectionObserverによる監視）を切り替える
 */
export function toggleVisualizerEcoMode(enabled) {
    isEcoModeEnabled = enabled;
    console.log(`[Visualizer] Eco Mode ${enabled ? 'ENABLED' : 'DISABLED'}.`);
    if (enabled) {
        if (observedTarget) setupVisualizerObserver(observedTarget);
    } else {
        disconnectVisualizerObserver();
        isVisualizerVisible = true;
        if (isPlaying()) {
            startVisualizerLoop();
        }
    }
}

/**
 * ビジュアライザーのIntersectionObserverをセットアップする
 */
function setupVisualizerObserver(targetElement) {
    disconnectVisualizerObserver();
    if (!isEcoModeEnabled || !targetElement) return;

    const options = {
        root: document.getElementById('music-list') || elements.mainContent,
        threshold: 0.1
    };

    visualizerObserver = new IntersectionObserver((entries) => {
        entries.forEach(entry => {
            const wasVisible = isVisualizerVisible;
            isVisualizerVisible = entry.isIntersecting;

            if (isVisualizerVisible) {
                if (!wasVisible && isPlaying()) {
                    startVisualizerLoop();
                }
            } else {
                if (currentVisualizerBars) {
                    lastHeights.fill(4);
                    currentVisualizerBars.forEach(bar => {
                        if (bar.style.height !== '4px') bar.style.height = '4px';
                    });
                }
            }
        });
    }, options);

    if (visualizerObserver) {
        visualizerObserver.observe(targetElement);
    }
}

/**
 * ビジュアライザーのIntersectionObserverを停止する
 */
export function disconnectVisualizerObserver() {
    if (visualizerObserver) {
        visualizerObserver.disconnect();
        visualizerObserver = null;
    }
}

/**
 * ビジュアライザーのFPS上限を設定する
 */
export function setVisualizerFpsLimit(fps) {
    const newFps = parseInt(fps, 10);
    if (isNaN(newFps) || newFps <= 0) {
        state.visualizerFpsLimit = 0;
        console.log('[Visualizer] FPS limit removed.');
    } else {
        state.visualizerFpsLimit = newFps;
        console.log(`[Visualizer] FPS limit set to ${newFps} FPS.`);
    }
}

/**
 * ビジュアライザーの描画関数 (requestAnimationFrameでループ)
 */
// Go path: double-buffer decoded frequency data (no per-fetch Uint8Array allocation)
let goFreqBufA = null;
let goFreqBufB = null;
let goFreqWriteToA = true;
/** @type {Uint8Array | null} */
let goPublishedFreq = null;
let goPublishedFreqLen = 0;
let isFetchingGoData = false;
let lastGoFetchTime = 0;

async function fetchGoData(timestamp = 0) {
    if (isFetchingGoData || !window.go) return;
    if (timestamp > 0 && timestamp - lastGoFetchTime < GO_VISUALIZER_FETCH_INTERVAL_MS) return;

    isFetchingGoData = true;
    lastGoFetchTime = timestamp || performance.now();
    try {
        const data = await window.go.main.App.AudioGetFrequencyData();

        if (data) {
            if (typeof data === 'string') {
                const binaryString = atob(data);
                const len = binaryString.length;
                if (len > 0) {
                    let target = goFreqWriteToA ? goFreqBufA : goFreqBufB;
                    if (!target || target.length < len) {
                        target = new Uint8Array(len);
                        if (goFreqWriteToA) {
                            goFreqBufA = target;
                        } else {
                            goFreqBufB = target;
                        }
                    }
                    for (let i = 0; i < len; i++) {
                        target[i] = binaryString.charCodeAt(i);
                    }
                    goPublishedFreq = target;
                    goPublishedFreqLen = len;
                    goFreqWriteToA = !goFreqWriteToA;
                }
            } else if (data instanceof Uint8Array && data.length > 0) {
                goPublishedFreq = data;
                goPublishedFreqLen = data.length;
            } else if (Array.isArray(data) && data.length > 0) {
                goPublishedFreq = new Uint8Array(data);
                goPublishedFreqLen = goPublishedFreq.length;
            }
        }
    } catch (e) {
        // エラー無視
    } finally {
        isFetchingGoData = false;
    }
}

/**
 * ビジュアライザーの描画関数 (requestAnimationFrameでループ)
 */
function draw(timestamp) {
    if (!isPlaying()) {
        visualizerFrameId = null;
        return;
    }
    visualizerFrameId = requestAnimationFrame(draw);

    if (resumeAudioContext) {
        resumeAudioContext();
    }

    if (isEcoModeEnabled && !isVisualizerVisible) return;
    if (state.isLightFlightMode || state.visualizerMode === 'static') return;

    if (state.visualizerFpsLimit > 0) {
        const frameInterval = 1000 / state.visualizerFpsLimit;
        const elapsed = timestamp - lastFrameTime;
        if (elapsed < frameInterval) return;
        lastFrameTime = timestamp - (elapsed % frameInterval);
    }

    let sourceData = null;
    let fftSize = 256; // Default
    let sampleRate = 48000; // Default

    if (window.go) {
        fetchGoData(timestamp); // 非同期でデータ更新
        if (goPublishedFreq && goPublishedFreqLen > 0) {
            sourceData = goPublishedFreq.subarray(0, goPublishedFreqLen);
            fftSize = goPublishedFreqLen * 2; // FFT size is usually 2x result stats
            // Go側のサンプルレートが不明だが、ここでは44100か48000と仮定
            // bin幅の計算に影響する
            sampleRate = 44100;
        }
    } else if (analyser && dataArray) {
        analyser.getByteFrequencyData(dataArray);
        sourceData = dataArray;
        fftSize = analyser.fftSize;
        sampleRate = analyser.context.sampleRate;
    }

    if (currentVisualizerBars && sourceData) {
        // iPhoneスタイルの対数スケール周波数配分
        // サンプルレート48kHz、FFTサイズ256の場合、各binは約187.5Hzの帯域幅
        // ターゲット周波数: 60Hz(低音), 250Hz, 1kHz, 4kHz, 8kHz, 16kHz(高音)
        // 対数スケールで均等に分散
        const targetFrequencies = [60, 250, 1000, 4000, 8000, 16000];
        const binWidth = sampleRate / fftSize;

        // 各ターゲット周波数に対応するビンインデックスを計算
        // 低周波数帯域では複数のビンを平均化してより滑らかな表示を実現
        const heights = targetFrequencies.map((freq, i) => {
            const centerBin = Math.round(freq / binWidth);

            // 周波数帯域に応じてビン範囲を調整（低音は広く、高音は狭く）
            let binRange = Math.max(1, Math.floor(3 - i * 0.4));

            // Goデータの場合、ビン配列の範囲内かチェック
            if (centerBin >= sourceData.length) return 4;

            const startBin = Math.max(0, centerBin - binRange);
            const endBin = Math.min(sourceData.length - 1, centerBin + binRange);

            // 範囲内のビンの平均値を計算
            let sum = 0;
            let count = 0;
            for (let b = startBin; b <= endBin; b++) {
                sum += sourceData[b];
                count++;
            }
            const avgValue = count > 0 ? sum / count / 255 : 0;

            // べき乗でダイナミクスを調整（低めの値を強調）
            const scaledValue = Math.pow(avgValue, 1.4);

            // 中央のバーを少し強調（視覚的なバランス調整）
            const multiplier = 1 + Math.sin((i / (targetFrequencies.length - 1)) * Math.PI) * 0.3;
            const targetHeight = (scaledValue * multiplier * 12) + 4;

            // スムージング（前フレームとの補間）
            const newHeight = lastHeights[i] * 0.4 + targetHeight * 0.6;
            lastHeights[i] = newHeight;
            return Math.min(20, Math.max(4, newHeight));
        });

        currentVisualizerBars.forEach((bar, index) => {
            const newHeightPx = `${heights[index]}px`;
            if (bar.style.height !== newHeightPx) {
                bar.style.height = newHeightPx;
            }
        });
    }
}

/**
 * ビジュアライザーの描画対象となる要素（インジケーター）を設定する
 */
export function setVisualizerTarget(targetElement) {
    // ▼▼▼ 修正箇所 ▼▼▼
    // ターゲットが既に同じ要素なら、何もしない
    if (observedTarget === targetElement) {
        return;
    }
    // ▲▲▲ 修正箇所 ▲▲▲

    document.querySelectorAll('.indicator-ready').forEach(item => {
        item.classList.remove('indicator-ready');
    });

    observedTarget = targetElement; // 監視対象を更新

    if (targetElement) {
        const bars = targetElement.querySelectorAll('.playing-indicator-bar');
        if (bars.length > 0) {
            targetElement.classList.add('indicator-ready');
            currentVisualizerBars = bars; // 現在の描画対象バーを更新
            setupVisualizerObserver(targetElement); // 新しいターゲットでObserverをセットアップ
        } else {
            currentVisualizerBars = null;
        }
    } else {
        // ターゲットがnull（再生停止時など）
        currentVisualizerBars = null;
        disconnectVisualizerObserver(); // Observerを停止
    }
}
