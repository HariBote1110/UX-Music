// @ts-nocheck
// src/renderer/js/wails-check.js
import { getWailsApp } from './bridge.js';

export async function checkWails() {
    const app = getWailsApp();
    if (app) {
        console.log('%c[Wails] Wails Environment Detected!', 'color: #00ff00; font-weight: bold;');
        try {
            const result = await app.Ping();
            console.log('[Wails] Ping Result:', result);

            // UIに表示するテスト
            const versionEl = document.getElementById('app-version');
            if (versionEl) {
                versionEl.textContent += ' (Wails Mode)';
            }
        } catch (err) {
            console.error('[Wails] Error calling Ping:', err);
        }
    }
}
