// src/renderer/js/visualizer.js

import { elements, state } from './state.js';
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

    if (currentVisualizerBars && analyser && dataArray) {
        analyser.getByteFrequencyData(dataArray);
        const barIndices = [1, 3, 7, 15, 30, 60];
        const heights = barIndices.map((dataIndex, i) => {
            const value = dataArray[dataIndex] / 255;
            const scaledValue = Math.pow(value, 1.6);
            const multiplier = 1 + Math.sin((i / (barIndices.length - 1)) * Math.PI) * 0.5;
            const targetHeight = (scaledValue * multiplier * 20) + 4;
            const newHeight = lastHeights[i] * 0.5 + targetHeight * 0.5;
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