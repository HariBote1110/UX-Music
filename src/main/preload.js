const { contextBridge, ipcRenderer } = require('electron');
const IPC_CHANNELS = require('./ipc-channels');

contextBridge.exposeInMainWorld('electronAPI', {
    CHANNELS: IPC_CHANNELS,

    // ipcRenderer の主要な機能をラップして公開
    send: (channel, ...args) => {
        const validChannels = Object.values(IPC_CHANNELS.SEND);
        if (validChannels.includes(channel)) {
            ipcRenderer.send(channel, ...args);
        } else {
            console.warn(`[IPC] Unauthorized send channel: ${channel}`);
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
