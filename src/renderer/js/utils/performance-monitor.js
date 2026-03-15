import { state } from '../core/state.js';
import { musicApi } from '../core/bridge.js';

const SAMPLE_INTERVAL_MS = 1000;
const REPORT_INTERVAL_MS = 5000;

let sampleTimerId = null;
let fpsFrameCount = 0;
let fpsLoopId = null;
let fpsLoopStartedAt = 0;

const samples = {
    rssMb: [],
    cpuPercent: [],
    goHeapMb: [],
    jsHeapMb: [],
    fps: [],
    domNodes: [],
    queueLength: [],
    lyricsLines: [],
};

function pushSample(bucket, value) {
    if (!Number.isFinite(value)) return;
    bucket.push(value);
}

function average(values) {
    if (!Array.isArray(values) || values.length === 0) return null;
    return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function clearSamples() {
    Object.values(samples).forEach((bucket) => {
        bucket.length = 0;
    });
}

function getJsHeapMb() {
    if (!performance.memory || !Number.isFinite(performance.memory.usedJSHeapSize)) {
        return null;
    }
    return performance.memory.usedJSHeapSize / 1024 / 1024;
}

function getDomNodeCount() {
    return document.getElementsByTagName('*').length;
}

function getLyricsLineCount() {
    return document.querySelectorAll('#lyrics-view p[data-index]').length;
}

function startFpsLoop() {
    fpsLoopStartedAt = performance.now();

    const tick = () => {
        fpsFrameCount += 1;
        fpsLoopId = requestAnimationFrame(tick);
    };

    fpsLoopId = requestAnimationFrame(tick);
}

function collectFpsSample() {
    const now = performance.now();
    const elapsed = now - fpsLoopStartedAt;
    if (elapsed <= 0) return;

    const fps = fpsFrameCount / (elapsed / 1000);
    pushSample(samples.fps, fps);

    fpsFrameCount = 0;
    fpsLoopStartedAt = now;
}

function formatAverage(value, digits = 1) {
    if (!Number.isFinite(value)) return 'n/a';
    return value.toFixed(digits);
}

function reportAverages() {
    const avgRss = average(samples.rssMb);
    const avgCpu = average(samples.cpuPercent);
    const avgGoHeap = average(samples.goHeapMb);
    const avgJsHeap = average(samples.jsHeapMb);
    const avgFps = average(samples.fps);
    const avgDomNodes = average(samples.domNodes);
    const avgQueueLength = average(samples.queueLength);
    const avgLyricsLines = average(samples.lyricsLines);

    console.log(
        `[Perf][5s avg] RSS=${formatAverage(avgRss)}MB CPU=${formatAverage(avgCpu)}% ` +
        `GoHeap=${formatAverage(avgGoHeap)}MB JSHeap=${formatAverage(avgJsHeap)}MB ` +
        `FPS=${formatAverage(avgFps)} DOM=${formatAverage(avgDomNodes, 0)} ` +
        `Queue=${formatAverage(avgQueueLength, 0)} Lyrics=${formatAverage(avgLyricsLines, 0)}`
    );

    clearSamples();
}

async function collectSample() {
    collectFpsSample();

    const snapshot = await musicApi.getPerformanceSnapshot().catch(() => null);
    if (snapshot) {
        pushSample(samples.rssMb, snapshot.processRssMb);
        pushSample(samples.cpuPercent, snapshot.processCpuPercent);
        pushSample(samples.goHeapMb, snapshot.goHeapAllocMb);
    }

    pushSample(samples.jsHeapMb, getJsHeapMb());
    pushSample(samples.domNodes, getDomNodeCount());
    pushSample(samples.queueLength, state.playbackQueue.length);
    pushSample(samples.lyricsLines, getLyricsLineCount());

    const collectedSampleCount = Math.max(
        samples.rssMb.length,
        samples.jsHeapMb.length,
        samples.fps.length,
        samples.domNodes.length,
        samples.queueLength.length,
        samples.lyricsLines.length
    );

    if (collectedSampleCount * SAMPLE_INTERVAL_MS >= REPORT_INTERVAL_MS) {
        reportAverages();
    }
}

export function startPerformanceMonitor() {
    if (sampleTimerId) {
        return;
    }

    startFpsLoop();
    sampleTimerId = window.setInterval(() => {
        collectSample().catch((error) => {
            console.warn('[Perf] Failed to collect performance sample:', error);
        });
    }, SAMPLE_INTERVAL_MS);

    console.log('[Perf] 5秒平均のパフォーマンスモニターを開始しました。');
}
