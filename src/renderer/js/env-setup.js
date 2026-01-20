// src/renderer/js/env-setup.js
// Wails などの非 Electron 環境でも動作するように、window.electronAPI を安全化する
window.electronAPI = window.electronAPI || {
    send: () => { },
    on: () => { },
    invoke: () => Promise.resolve(null),
    removeAllListeners: () => { },
    CHANNELS: {
        SEND: {},
        INVOKE: {},
        ON: {}
    }
};
