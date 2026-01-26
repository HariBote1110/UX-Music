const RPC = require('discord-rpc');
const clientId = '1417754671895806062';

let rpc;
let startTimestamp;

const activityCache = {
    details: '',
    state: ''
};

async function connectToDiscord() {
    if (rpc) return;

    rpc = new RPC.Client({ transport: 'ipc' });

    rpc.on('ready', () => {
        console.log('[Discord RPC] Connected to Discord.');
    });

    try {
        await rpc.login({ clientId });
    } catch (error) {
        console.error('[Discord RPC] Failed to connect:', error.message);
        rpc = null;
    }
}

async function setActivity(song) {
    if (!rpc || !song) return;
    
    const newDetails = song.title.substring(0, 128);
    const newState = `by ${song.artist}`.substring(0, 128);

    if (activityCache.details === newDetails && activityCache.state === newState) {
        return;
    }

    activityCache.details = newDetails;
    activityCache.state = newState;
    startTimestamp = new Date();
    
    const activity = {
        details: newDetails,
        state: newState,
        startTimestamp,
        largeImageKey: 'ux_music_icon', // アセット名をアンダースコアに変更
        largeImageText: 'UX Music',
        instance: false,
    };
    
    try {
        await rpc.setActivity(activity);
    } catch (error) {
        console.error('[Discord RPC] Failed to set activity:', error.message);
    }
}

async function clearActivity() {
    if (!rpc) return;
    
    activityCache.details = '';
    activityCache.state = '';
    
    try {
        await rpc.clearActivity();
    } catch (error) {
        console.error('[Discord RPC] Failed to clear activity:', error.message);
    }
    startTimestamp = null;
}

module.exports = { connectToDiscord, setActivity, clearActivity };