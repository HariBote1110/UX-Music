// src/renderer/js/wails-check.js
export async function checkWails() {
    if (window.go && window.go.main && window.go.main.App) {
        console.log('%c[Wails] Wails Environment Detected!', 'color: #00ff00; font-weight: bold;');
        try {
            const result = await window.go.main.App.Ping();
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
