// src/renderer/js/ui/equalizer/graphic-equaliser.ts
// サイドバー版・設定画面版で共有するグラフィックEQコンポーネント。
// DOM の構築/描画のみを担当し、状態の読み書きと永続化はコールバック経由で
// equalizer.ts 側に委譲する（単一の状態ソースは呼び出し側が持つ state.equalizerSettings）。

import {
    BAND_FREQUENCIES,
    EQ_PRESETS,
    MAX_DB,
    MIN_DB,
    dbToY,
    freqToX,
    nearestBandIndex,
    xToFreq,
    yToDb,
} from './eq-maths.js';

export type EqLayoutMode = 'sidebar' | 'settings';

export interface GraphicEqualiserCallbacks {
    /** 現在の EQ 設定を取得する（唯一の情報源）。 */
    getState: () => { active: boolean; preamp: number; bands: number[] };
    /** バンド値をドラッグ中に呼ばれる。即座に音声へ反映してよい（保存は別途デバウンスされる）。 */
    onBandsChange: (bands: number[]) => void;
    /** プリセット選択時に呼ばれる。 */
    onPresetChange: (presetName: string) => void;
    /** リセットボタン押下時に呼ばれる。 */
    onReset: () => void;
    /** 有効/無効トグル切り替え時に呼ばれる。 */
    onToggleActive: (active: boolean) => void;
    /** ドラッグ確定（mouseup）や設定変更確定時に呼ばれる。永続化のトリガー。 */
    onCommit: () => void;
}

interface MountedInstance {
    container: HTMLElement;
    mode: EqLayoutMode;
    canvas: HTMLCanvasElement;
    presetSelect: HTMLSelectElement;
    toggle: HTMLInputElement;
    readout: HTMLElement;
    resizeObserver: ResizeObserver;
    draw: () => void;
    dispose: () => void;
}

// container ごとに1インスタンスだけを保持する（再マウント時は破棄してから作り直す）。
const instancesByContainer = new WeakMap<HTMLElement, MountedInstance>();
const allInstances = new Set<MountedInstance>();

function formatFreqLabel(freq: number): string {
    return freq < 1000 ? `${freq}` : `${freq / 1000}k`;
}

/**
 * container 内にグラフィックEQを描画する。同じ container への再呼び出しは
 * 既存インスタンスを破棄して作り直すため、要素が重複することはない（冪等）。
 */
export function mountGraphicEqualiser(
    container: HTMLElement,
    mode: EqLayoutMode,
    callbacks: GraphicEqualiserCallbacks,
): void {
    unmountGraphicEqualiser(container);

    container.innerHTML = '';
    container.classList.add('graphic-eq', `graphic-eq--${mode}`);

    const header = document.createElement('div');
    header.className = 'graphic-eq-header';

    const toggleLabel = document.createElement('label');
    toggleLabel.className = 'switch graphic-eq-toggle';
    const toggle = document.createElement('input');
    toggle.type = 'checkbox';
    const toggleSlider = document.createElement('span');
    toggleSlider.className = 'slider round';
    toggleLabel.append(toggle, toggleSlider);

    const presetSelect = document.createElement('select');
    presetSelect.className = 'graphic-eq-preset-select';
    const customOption = document.createElement('option');
    customOption.value = 'Custom';
    customOption.textContent = 'カスタム';
    presetSelect.appendChild(customOption);
    Object.keys(EQ_PRESETS).forEach(name => {
        const option = document.createElement('option');
        option.value = name;
        option.textContent = name;
        presetSelect.appendChild(option);
    });

    const resetBtn = document.createElement('button');
    resetBtn.type = 'button';
    resetBtn.className = 'graphic-eq-reset-btn';
    resetBtn.textContent = 'リセット';

    header.append(toggleLabel, presetSelect, resetBtn);

    const canvasWrap = document.createElement('div');
    canvasWrap.className = 'graphic-eq-canvas-wrap';
    const canvas = document.createElement('canvas');
    canvas.className = 'graphic-eq-canvas';
    canvasWrap.appendChild(canvas);

    const readout = document.createElement('div');
    readout.className = 'graphic-eq-readout';

    container.append(header, canvasWrap, readout);

    const ctx = canvas.getContext('2d');

    let draggingPoint = -1;
    let canvasWidth = 0;
    let canvasHeight = 0;

    const renderReadout = () => {
        const { bands } = callbacks.getState();
        readout.innerHTML = BAND_FREQUENCIES.map((freq, i) => {
            const value = bands[i] ?? 0;
            const sign = value > 0 ? '+' : '';
            return `<span class="graphic-eq-readout-band"><b>${formatFreqLabel(freq)}Hz</b>${sign}${value.toFixed(1)}dB</span>`;
        }).join('');
    };

    const draw = () => {
        if (!ctx) return;
        const dpr = window.devicePixelRatio || 1;
        const rect = canvas.getBoundingClientRect();
        if (rect.width === 0 || rect.height === 0) return;
        canvasWidth = rect.width;
        canvasHeight = rect.height;
        canvas.width = Math.round(rect.width * dpr);
        canvas.height = Math.round(rect.height * dpr);
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        ctx.clearRect(0, 0, canvasWidth, canvasHeight);

        ctx.strokeStyle = 'rgba(255, 255, 255, 0.12)';
        ctx.fillStyle = '#888';
        ctx.font = '10px sans-serif';
        for (let db = MIN_DB; db <= MAX_DB; db += 6) {
            const y = dbToY(db, canvasHeight);
            ctx.beginPath();
            ctx.moveTo(0, y);
            ctx.lineTo(canvasWidth, y);
            ctx.stroke();
            if (db !== 0) ctx.fillText(`${db}`, 4, y - 2);
        }
        BAND_FREQUENCIES.forEach(freq => {
            const x = freqToX(freq, canvasWidth);
            ctx.beginPath();
            ctx.moveTo(x, 0);
            ctx.lineTo(x, canvasHeight);
            ctx.stroke();
            ctx.fillText(formatFreqLabel(freq), x + 4, canvasHeight - 4);
        });

        const { bands } = callbacks.getState();
        const points = BAND_FREQUENCIES.map((freq, i) => ({
            x: freqToX(freq, canvasWidth),
            y: dbToY(bands[i] ?? 0, canvasHeight),
        }));

        ctx.strokeStyle = 'var(--highlight-pink)';
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.moveTo(0, points[0].y);
        points.forEach(p => ctx.lineTo(p.x, p.y));
        ctx.lineTo(canvasWidth, points[points.length - 1].y);
        ctx.stroke();

        points.forEach((p, i) => {
            ctx.fillStyle = i === draggingPoint ? '#fff' : 'var(--highlight-pink)';
            ctx.beginPath();
            ctx.arc(p.x, p.y, 5, 0, 2 * Math.PI);
            ctx.fill();
        });
    };

    const syncControls = () => {
        const { active, bands } = callbacks.getState();
        toggle.checked = active;
        container.classList.toggle('graphic-eq--inactive', !active);
        const matchedPreset = Object.keys(EQ_PRESETS).find(name =>
            EQ_PRESETS[name].every((v, i) => Math.abs(v - (bands[i] ?? 0)) < 0.001),
        );
        presetSelect.value = matchedPreset ?? 'Custom';
        renderReadout();
    };

    const refresh = () => {
        syncControls();
        draw();
    };

    const resizeObserver = new ResizeObserver(() => draw());
    resizeObserver.observe(canvasWrap);

    canvas.addEventListener('mousedown', e => {
        const rect = canvas.getBoundingClientRect();
        const x = e.clientX - rect.left;
        const y = e.clientY - rect.top;
        const { bands } = callbacks.getState();
        draggingPoint = nearestBandIndex(x, y, canvasWidth, canvasHeight, bands);
    });
    canvas.addEventListener('mousemove', e => {
        if (draggingPoint === -1) return;
        const rect = canvas.getBoundingClientRect();
        const y = e.clientY - rect.top;
        const db = Math.round(Math.max(MIN_DB, Math.min(MAX_DB, yToDb(y, canvasHeight))) * 10) / 10;
        const { bands } = callbacks.getState();
        const nextBands = [...bands];
        nextBands[draggingPoint] = db;
        callbacks.onBandsChange(nextBands);
        refreshAllInstances();
    });
    const onMouseUpOrLeave = () => {
        if (draggingPoint !== -1) {
            draggingPoint = -1;
            callbacks.onCommit();
            refreshAllInstances();
        }
    };
    canvas.addEventListener('mouseup', onMouseUpOrLeave);
    canvas.addEventListener('mouseleave', onMouseUpOrLeave);

    toggle.addEventListener('change', () => {
        callbacks.onToggleActive(toggle.checked);
        callbacks.onCommit();
        refreshAllInstances();
    });
    presetSelect.addEventListener('change', () => {
        if (presetSelect.value === 'Custom') return;
        callbacks.onPresetChange(presetSelect.value);
        callbacks.onCommit();
        refreshAllInstances();
    });
    resetBtn.addEventListener('click', () => {
        callbacks.onReset();
        callbacks.onCommit();
        refreshAllInstances();
    });

    const instance: MountedInstance = {
        container,
        mode,
        canvas,
        presetSelect,
        toggle,
        readout,
        resizeObserver,
        draw: refresh,
        dispose: () => resizeObserver.disconnect(),
    };
    instancesByContainer.set(container, instance);
    allInstances.add(instance);

    requestAnimationFrame(refresh);
}

/** container からグラフィックEQを取り外し、リスナー類を解放する。 */
export function unmountGraphicEqualiser(container: HTMLElement): void {
    const existing = instancesByContainer.get(container);
    if (!existing) return;
    existing.dispose();
    allInstances.delete(existing);
    instancesByContainer.delete(container);
}

/** マウント済みの全インスタンスを最新の state で再描画する。 */
export function refreshAllInstances(): void {
    allInstances.forEach(instance => instance.draw());
}
