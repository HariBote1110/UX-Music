// src/renderer/js/ui/equalizer.js
import { state, elements } from '../core/state.js';
import { applyEqualizerSettings } from '../features/audio-graph.js';
import { musicApi } from '../core/bridge.js';

// ... (frequencies, presets, saveSettings, applyPreset, applyCurrentSettings は変更なし) ...
const frequencies = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
const presets = {
    'Flat': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    'Electronic': [7, 5, 2, 0, -2, 0, 2, 3, 4, 5],
    'Rock': [5, 3, 1, -2, -1, 1, 3, 4, 5, 6],
    'Pop': [-2, 0, 2, 4, 5, 3, 0, -1, -2, -3],
    'Jazz': [4, 2, 1, -2, -2, 0, 1, 2, 3, 4],
    'Classical': [5, 4, 2, -2, -3, -2, 0, 1, 2, 3],
    'Vocal': [-2, -1, 0, 3, 4, 2, 1, 0, -1, -2]
};
function saveSettings() {
    musicApi.saveSettings({ equalizer: state.equalizerSettings });
}
function applyPreset(presetName) {
    const bands = presets[presetName];
    if (!bands) return;
    state.equalizerSettings.bands = [...bands];
    state.equalizerSettings.bass = 0;
    state.equalizerSettings.mid = 0;
    state.equalizerSettings.treble = 0;
    applyCurrentSettings();
    renderEqualizer();
    renderGraphicEQ();
    const sidebarSelect = document.getElementById('eq-preset-select');
    const graphicEqSelect = document.getElementById('graphic-eq-preset-select');
    if (sidebarSelect) sidebarSelect.value = presetName;
    if (graphicEqSelect) graphicEqSelect.value = presetName;
    saveSettings();
}
export function applyCurrentSettings() {
    const { active, bass, mid, treble, bands, preamp } = state.equalizerSettings;
    if (!active) {
        applyEqualizerSettings({ active: false, preamp: 0, bands: Array(10).fill(0) });
        return;
    }
    const finalBands = [...bands];
    finalBands[0] += bass; finalBands[1] += bass; finalBands[2] += bass * 0.5;
    finalBands[3] += mid * 0.5; finalBands[4] += mid; finalBands[5] += mid; finalBands[6] += mid * 0.5;
    finalBands[7] += treble * 0.5; finalBands[8] += treble; finalBands[9] += treble;
    applyEqualizerSettings({ active: true, preamp, bands: finalBands });
}

export function renderEqualizer() {
    // ▼▼▼ 安全策追加 ▼▼▼
    const view = elements.equalizerView;
    if (!view) return;
    // ▲▲▲ 追加 ▲▲▲

    const { active, bass, mid, treble } = state.equalizerSettings;

    if (!view.innerHTML && document.getElementById('eq-toggle') === null) return;

    const toggle = document.getElementById('eq-toggle');
    if (toggle) toggle.checked = active;

    const bassSlider = document.getElementById('eq-bass-slider');
    if (bassSlider) bassSlider.value = bass;

    const midSlider = document.getElementById('eq-mid-slider');
    if (midSlider) midSlider.value = mid;

    const trebleSlider = document.getElementById('eq-treble-slider');
    if (trebleSlider) trebleSlider.value = treble;

    const controlsWrapper = document.getElementById('eq-controls-wrapper');
    if (controlsWrapper) {
        if (active) {
            controlsWrapper.classList.remove('eq-inactive');
        } else {
            controlsWrapper.classList.add('eq-inactive');
        }
    }
}

export function renderGraphicEQ() {
    const container = document.getElementById('graphic-eq-container');
    if (!container) return;

    const { preamp, bands } = state.equalizerSettings;

    container.innerHTML = `
        <div class="graphic-eq-header">
            <select id="graphic-eq-preset-select">
                <option value="Custom">カスタム</option>
                ${Object.keys(presets).map(p => `<option value="${p}">${p}</option>`).join('')}
            </select>
            <button id="graphic-eq-reset-btn">リセット</button>
        </div>
        <canvas id="graphic-eq-canvas"></canvas>
    `;

    const canvas = document.getElementById('graphic-eq-canvas');
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    // ... (Drawing logic remains same) ...
    let draggingPoint = -1;
    const minFreq = 20; const maxFreq = 20000;
    const logMin = Math.log10(minFreq); const logMax = Math.log10(maxFreq);
    let canvasWidth = 0; let canvasHeight = 0;
    const freqToX = (freq) => (Math.log10(freq) - logMin) / (logMax - logMin) * canvasWidth;
    const dbToY = (db) => (1 - (db + 12) / 24) * canvasHeight;
    const yToDb = (y) => (1 - y / canvasHeight) * 24 - 12;

    const draw = () => {
        const dpr = window.devicePixelRatio || 1;
        const rect = canvas.getBoundingClientRect();
        if (rect.width === 0 || rect.height === 0) { requestAnimationFrame(draw); return; }
        canvas.width = rect.width * dpr; canvas.height = rect.height * dpr;
        ctx.scale(dpr, dpr); canvasWidth = rect.width; canvasHeight = rect.height;
        ctx.clearRect(0, 0, canvasWidth, canvasHeight);
        ctx.strokeStyle = '#333'; ctx.fillStyle = '#888'; ctx.font = '10px sans-serif';
        for (let db = -12; db <= 12; db += 6) {
            const y = dbToY(db); ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(canvasWidth, y); ctx.stroke();
            if (db !== 0) ctx.fillText(`${db}`, 5, y - 2);
        }
        frequencies.forEach(f => {
            const x = freqToX(f); ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, canvasHeight); ctx.stroke();
            const label = f < 1000 ? f : `${f / 1000}k`; ctx.fillText(label, x + 5, canvasHeight - 5);
        });
        const points = frequencies.map((freq, i) => ({ x: freqToX(freq), y: dbToY(state.equalizerSettings.bands[i]) }));
        ctx.strokeStyle = 'var(--highlight-pink)'; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(0, points[0].y);
        for (let i = 0; i < points.length; i++) { ctx.lineTo(points[i].x, points[i].y); }
        ctx.lineTo(canvasWidth, points[points.length - 1].y); ctx.stroke();
        points.forEach((p, i) => {
            ctx.fillStyle = i === draggingPoint ? '#fff' : 'var(--highlight-pink)';
            ctx.beginPath(); ctx.arc(p.x, p.y, 5, 0, 2 * Math.PI); ctx.fill();
        });
    };
    canvas.addEventListener('mousedown', (e) => {
        const rect = canvas.getBoundingClientRect(); const x = e.clientX - rect.left; const y = e.clientY - rect.top;
        const points = frequencies.map((freq, i) => ({ x: freqToX(freq), y: dbToY(state.equalizerSettings.bands[i]) }));
        for (let i = 0; i < points.length; i++) { if (Math.hypot(points[i].x - x, points[i].y - y) < 10) { draggingPoint = i; break; } }
    });
    canvas.addEventListener('mousemove', (e) => {
        if (draggingPoint === -1) return;
        const rect = canvas.getBoundingClientRect(); const y = e.clientY - rect.top;
        const db = Math.round(Math.max(-12, Math.min(12, yToDb(y))));
        state.equalizerSettings.bands[draggingPoint] = db;
        state.equalizerSettings.bass = 0; state.equalizerSettings.mid = 0; state.equalizerSettings.treble = 0;
        applyCurrentSettings(); renderEqualizer();
        document.getElementById('eq-preset-select').value = 'Custom'; document.getElementById('graphic-eq-preset-select').value = 'Custom';
        draw();
    });
    const onMouseUpOrLeave = () => { if (draggingPoint !== -1) { draggingPoint = -1; draw(); saveSettings(); } };
    canvas.addEventListener('mouseup', onMouseUpOrLeave); canvas.addEventListener('mouseleave', onMouseUpOrLeave);
    document.getElementById('graphic-eq-preset-select').addEventListener('change', (e) => applyPreset(e.target.value));
    document.getElementById('graphic-eq-reset-btn').addEventListener('click', () => applyPreset('Flat'));
    requestAnimationFrame(draw);
}

export function initEqualizer() {
    // ▼▼▼ 安全策追加 ▼▼▼
    if (!elements.equalizerView) {
        console.warn('[Equalizer] View element not found. Initialization skipped.');
        return;
    }
    // ▲▲▲ 追加 ▲▲▲

    const container = elements.equalizerView;
    container.innerHTML = `
        <div class="equalizer-header">
            <label class="switch">
                <input type="checkbox" id="eq-toggle">
                <span class="slider round"></span>
            </label>
        </div>
        <div id="eq-controls-wrapper">
            <div class="equalizer-presets">
                <select id="eq-preset-select">
                    <option value="Custom">カスタム</option>
                    ${Object.keys(presets).map(p => `<option value="${p}">${p}</option>`).join('')}
                </select>
            </div>
            <div class="simple-eq-bands">
                <div class="simple-eq-band"><label>Bass</label><input type="range" id="eq-bass-slider" min="-6" max="6" step="1" value="0"></div>
                <div class="simple-eq-band"><label>Mid</label><input type="range" id="eq-mid-slider" min="-6" max="6" step="1" value="0"></div>
                <div class="simple-eq-band"><label>Treble</label><input type="range" id="eq-treble-slider" min="-6" max="6" step="1" value="0"></div>
            </div>
            <div class="equalizer-footer"><button id="open-graphic-eq-btn">詳細設定...</button></div>
        </div>
    `;

    const toggle = document.getElementById('eq-toggle');
    if (toggle) toggle.addEventListener('change', (e) => {
        state.equalizerSettings.active = e.target.checked; applyCurrentSettings(); renderEqualizer(); saveSettings();
    });
    const presetSelect = document.getElementById('eq-preset-select');
    if (presetSelect) presetSelect.addEventListener('change', (e) => { if (e.target.value !== 'Custom') applyPreset(e.target.value); });

    ['bass', 'mid', 'treble'].forEach(type => {
        const slider = document.getElementById(`eq-${type}-slider`);
        if (slider) {
            slider.addEventListener('input', (e) => {
                state.equalizerSettings[type] = parseFloat(e.target.value); applyCurrentSettings();
                const ps = document.getElementById('eq-preset-select'); if (ps) ps.value = 'Custom';
            });
            slider.addEventListener('change', saveSettings);
            slider.addEventListener('dblclick', (e) => { e.target.value = 0; state.equalizerSettings[type] = 0; applyCurrentSettings(); saveSettings(); });
        }
    });

    const openBtn = document.getElementById('open-graphic-eq-btn');
    if (openBtn) openBtn.addEventListener('click', () => { elements.settingsModalOverlay.classList.remove('hidden'); renderGraphicEQ(); });

    renderEqualizer();
}
