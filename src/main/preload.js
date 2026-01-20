console.log('[Preload] Initializing...');
const { contextBridge, ipcRenderer } = require('electron');
const IPC_CHANNELS = require('./ipc-channels');

console.log('[Preload] IPC_CHANNELS loaded:', Object.keys(IPC_CHANNELS).length, 'keys');

contextBridge.exposeInMainWorld('electronAPI', {
    CHANNELS: IPC_CHANNELS,

    // ipcRenderer の主要な機能をラップして公開
    send: (channel, ...args) => {
        // console.log(`[Preload] Sending IPC: ${channel}`);
        const validChannels = Object.values(IPC_CHANNELS.SEND);
        if (validChannels.includes(channel)) {
            ipcRenderer.send(channel, ...args);
        } else {
            console.error(`[IPC] Blocked unauthorized send channel: ${channel}`);
        }
    },
    invoke: (channel, ...args) => {
        const validChannels = Object.values(IPC_CHANNELS.INVOKE);
        if (validChannels.includes(channel)) {
            return ipcRenderer.invoke(channel, ...args);
        } else {
            console.warn(`[IPC] Unauthorized invoke channel: ${channel}`);
        }
    },
    on: (channel, func) => {
        const validChannels = Object.values(IPC_CHANNELS.ON);
        if (validChannels.includes(channel)) {
            const subscription = (event, ...args) => func(...args);
            ipcRenderer.on(channel, subscription);
            return () => ipcRenderer.removeListener(channel, subscription);
        } else {
            console.warn(`[IPC] Unauthorized on channel: ${channel}`);
        }
    },
    removeAllListeners: (channel) => {
        ipcRenderer.removeAllListeners(channel);
    }
});
