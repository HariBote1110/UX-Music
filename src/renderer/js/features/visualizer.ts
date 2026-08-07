// src/renderer/js/visualizer.js

import { elements, state } from '../core/state.js';
import { analyser, dataArray, resumeAudioContext } from './audio-graph.js';
import { isPlaying } from './player.js';
import { getWailsApp } from '../core/bridge.js';
import { computeBarHeights, createVisualizerState } from './visualizer-mapping.js';

let visualizerFrameId = null;
let currentVisualizerBars = null;
let observedTarget = null;
let visualizerState = createVisualizerState();
let lastFrameTime = 0;
let lastDrawTimestamp = 0;
let visualizerObserver = null;
let isVisualizerVisible = false;
let isEcoModeEnabled = true;
const GO_VISUALIZER_FETCH_INTERVAL_MS = 40;

/**
 * ビジュアライザーの描画ループを開始する
 */
export function startVisualizerLoop() {
    visualizerState = createVisualizerState();
    lastDrawTimestamp = 0;

    if (window.go && goFetchIntervalId == null) {
        goFetchIntervalId = setInterval(() => {
            void fetchGoData();
        }, GO_VISUALIZER_FETCH_INTERVAL_MS);
        void fetchGoData();
    }

    if (!visualizerFrameId && isPlaying()) {
        visualizerFrameId = requestAnimationFrame(draw);
    }
}

/**
 * ビジュアライザーの描画ループを停止する
 */
export function stopVisualizerLoop() {
    if (goFetchIntervalId != null) {
        clearInterval(goFetchIntervalId);
        goFetchIntervalId = null;
    }
    if (visualizerFrameId) {
        cancelAnimationFrame(visualizerFrameId);
        visualizerFrameId = null;
    }
    if (currentVisualizerBars) {
        visualizerState = createVisualizerState();
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
                    visualizerState = createVisualizerState();
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
        state.userPreferredVisualizerFps = 0;
        console.log('[Visualizer] FPS limit removed.');
    } else {
        state.userPreferredVisualizerFps = newFps;
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
/** @type {ReturnType<typeof setInterval> | null} */
let goFetchIntervalId = null;

async function fetchGoData() {
    if (isFetchingGoData || !getWailsApp()) return;
    if (state.visualizerMode === 'static') return;
    if (isEcoModeEnabled && !isVisualizerVisible) return;

    isFetchingGoData = true;
    try {
        const data = await getWailsApp()?.AudioGetFrequencyData?.();

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
    if (state.visualizerMode === 'static') return;

    if (state.userPreferredVisualizerFps > 0) {
        const frameInterval = 1000 / state.userPreferredVisualizerFps;
        const elapsed = timestamp - lastFrameTime;
        if (elapsed < frameInterval) return;
        lastFrameTime = timestamp - (elapsed % frameInterval);
    }

    let sourceData = null;
    let fftSize = 256; // Default
    let sampleRate = 48000; // Default

    if (window.go) {
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
        // 聴覚特性ベースのマッピング（対数バンドのエネルギー平均 → ノイズゲート →
        // 等ラウドネス補正 → アタック/リリース非対称スムージング）は
        // visualizer-mapping.js に切り出し、単体テスト可能にしている。
        const dtMs = lastDrawTimestamp === 0 ? 16.7 : timestamp - lastDrawTimestamp;
        lastDrawTimestamp = timestamp;

        const heights = computeBarHeights(sourceData, sampleRate, fftSize, visualizerState, dtMs);

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
