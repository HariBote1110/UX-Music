/**
 * Discord RPC Manager - Go Sidecar 経由版
 * 実際の Discord 通信は Go 側で行う
 */

const sidecarManager = require('./sidecar-manager');

let connected = false;

async function connectToDiscord() {
    if (connected) return;

    try {
        await sidecarManager.invoke('discord-connect', {});
        connected = true;
        console.log('[Discord RPC] Connected via Go sidecar.');
    } catch (error) {
        console.error('[Discord RPC] Failed to connect:', error.message);
    }
}

async function setActivity(song) {
    if (!song) return;

    try {
        await sidecarManager.invoke('discord-set-activity', {
            title: song.title || 'Unknown',
            artist: song.artist || 'Unknown Artist'
        });
    } catch (error) {
        // エラーは静かに処理（Discord が起動していない場合など）
        console.warn('[Discord RPC] Failed to set activity:', error.message);
    }
}

async function clearActivity() {
    try {
        await sidecarManager.invoke('discord-clear', {});
    } catch (error) {
        console.warn('[Discord RPC] Failed to clear activity:', error.message);
    }
}

module.exports = { connectToDiscord, setActivity, clearActivity };