// src/renderer/renderer.js
import './js/core/env-setup.js';
import { state, elements, initElements } from './js/core/state.js';
import { initEventListeners } from './js/core/init-listeners.js';
import { initUI } from './js/ui/ui.js';
import { initSettings } from './js/utils/init-settings.js';
import { initNavigation, showView } from './js/core/navigation.js';
import { initPlayer, playCurrent, pauseCurrent, togglePlayPause, stop as stopPlayback } from './js/features/player.js';
import { updateAudioDevices, updatePlayCountDisplay, addSongsToLibrary } from './js/ui/ui-manager.js';
import { restoreSavedSinkId } from './js/features/audio-graph.js';
import { loadAllComponents } from './js/ui/component-loader.js';
import { initIPC } from './js/core/ipc.js';
import { initModal } from './js/ui/modal.js';
import { initDebugCommands } from './js/utils/debug-commands.js';
import { initNormalizeView } from './js/features/normalize-view.js';
import { initEqualizer } from './js/ui/equalizer.js';
import { initQuiz } from './js/features/quiz.js';
// ▼▼▼ 修正: playNextSong, playPrevSong を適切にインポート ▼▼▼
import { playNextSong, playPrevSong } from './js/features/playback-manager.js';
import { initLazyLoader, observeNewImages } from './js/utils/lazy-loader.js';
import { musicApi } from './js/core/bridge.js';
import { checkWails } from './js/core/wails-check.js';

window.onerror = function (msg, url, line, col, error) {
    console.error(`[Global Error] ${msg} at ${url}:${line}:${col}`, error);
    return false;
};

window.onunhandledrejection = function (event) {
    console.error('[Unhandled Rejection]', event.reason);
};

const electronAPI = window.electronAPI;

window.artworkLoadTimes = [];
window.observeNewArtworks = (container) => observeNewImages(container || document);

async function initApp() {
    console.log('App initializing...');

    try {
        await loadAllComponents();
        console.log('Components loaded.');
    } catch (e) {
        console.error('Failed to load components:', e);
    }

    try {
        initElements();
    } catch (e) {
        console.error('Failed to init elements:', e);
    }

    initLazyLoader(elements.mainContent);

    const safeInit = (fn, name) => {
        try { fn(); } catch (e) { console.error(`Failed to init ${name}:`, e); }
    };

    safeInit(initUI, 'UI');
    safeInit(initNavigation, 'Navigation');
    safeInit(initEventListeners, 'EventListeners');
    safeInit(initSettings, 'Settings');
    safeInit(initModal, 'Modal');
    safeInit(initDebugCommands, 'DebugCommands');
    safeInit(initNormalizeView, 'NormalizeView');
    safeInit(initQuiz, 'Quiz');
    safeInit(initEqualizer, 'Equalizer');

    const mainPlayer = document.getElementById('main-player');
    if (mainPlayer) {
        // ▼▼▼ 修正: player.js のコールバックで playback-manager の関数を呼ぶように変更 ▼▼▼
        // これにより、曲遷移時に state.currentSongIndex が正しく更新され、UIが同期されます。
        await initPlayer(mainPlayer, {
            onSongEnded: () => {
                console.log('[Renderer] 曲が終了しました。次を再生します。');
                playNextSong();
            },
            onNextSong: () => {
                console.log('[Renderer] 次へボタンが押されました。');
                playNextSong();
            },
            onPrevSong: () => {
                console.log('[Renderer] 前へボタンが押されました。');
                playPrevSong();
            }
        });
        // ▲▲▲ 修正完了 ▲▲▲
    }

    electronAPI.on('os-media-command', (command) => {
        switch (command) {
            case 'play':
                void playCurrent();
                break;
            case 'pause':
                void pauseCurrent();
                break;
            case 'toggle':
                void togglePlayPause();
                break;
            case 'next':
                playNextSong();
                break;
            case 'previous':
                playPrevSong();
                break;
            case 'stop':
                void stopPlayback();
                break;
            default:
                break;
        }
    });

    musicApi.onAppInfoResponse((info) => {
        const appVersionEl = document.getElementById('app-version');
        if (appVersionEl) appVersionEl.textContent = `v${info.version}`;
    });

    musicApi.onLoadLibrary(async (data) => {
        if (!state.artworksDir) state.artworksDir = await musicApi.getArtworksDir();
        addSongsToLibrary({ songs: data.songs || [], albums: data.albums || {} });

        const initialView = state.activeViewId || 'track-view';
        showView(initialView);

        musicApi.requestPlaylistsWithArtwork();
        const loadingOverlay = document.getElementById('loading-overlay');
        if (loadingOverlay) loadingOverlay.classList.add('hidden');
    });

    electronAPI.on('settings-loaded', (settings) => {
        if (typeof settings.volume === 'number') {
            if (elements.volumeSlider) elements.volumeSlider.value = settings.volume;
        }
        state.visualizerMode = settings.visualizerMode || 'active';

        // オーディオ出力デバイスの設定を復元
        if (settings.audioOutputId) {
            restoreSavedSinkId(settings.audioOutputId);
        }

        if (typeof settings.isShuffled === 'boolean') {
            state.isShuffled = settings.isShuffled;
            if (elements.shuffleBtn) elements.shuffleBtn.classList.toggle('active', state.isShuffled);
        }
        if (typeof settings.groupAlbumArt === 'boolean') {
            state.groupAlbumArt = settings.groupAlbumArt;
            if (state.activeViewId === 'track-view') showView('track-view');
        }
        if (settings.enableYouTube) {
            document.querySelectorAll('[data-feature="youtube"]').forEach(el => el.classList.remove('hidden'));
        }
    });

    musicApi.onPlayCountsUpdated((counts) => {
        state.playCounts = counts;
        Object.keys(counts).forEach(songPath => updatePlayCountDisplay(songPath, counts[songPath].count));
    });

    musicApi.onPlaylistsUpdated((playlists) => {
        state.playlists = playlists;
        if (state.activeViewId === 'playlist-view') showView('playlist-view');
    });

    musicApi.onForceReloadPlaylist(async (playlistName) => {
        if (state.currentDetailView.type === 'playlist' && state.currentDetailView.identifier === playlistName) {
            const updatedDetails = await musicApi.getPlaylistDetails(playlistName);
            state.currentlyViewedSongs = updatedDetails.songs;
            showView('playlist-detail-view', { type: 'playlist', identifier: playlistName, data: updatedDetails });
        }
    });

    // ▼▼▼ 追加: スキャン完了時にライブラリを更新 ▼▼▼
    electronAPI.on('scan-complete', (newSongs) => {
        console.log(`[Renderer] スキャン完了: ${newSongs?.length || 0}曲が追加されました`);
        if (newSongs && newSongs.length > 0) {
            addSongsToLibrary({ songs: newSongs, albums: {} });
            // 通知を表示（ipc.js の showNotification をインポートできない場合は直接表示）
            const notification = document.getElementById('notification');
            if (notification) {
                notification.textContent = `${newSongs.length}曲がライブラリに追加されました`;
                notification.classList.add('visible');
                setTimeout(() => notification.classList.remove('visible'), 3000);
            }
        } else if (window.go) {
            // In Wails mode, refresh from persisted library to recover from stale in-memory state.
            musicApi.loadLibrary();
        }
    });
    // ▲▲▲ 追加ここまで ▲▲▲

    musicApi.requestAppInfo();
    musicApi.requestInitialPlayCounts();

    try {
        const settings = await musicApi.getSettings();
        if (settings) {
            if (typeof settings.volume === 'number') {
                if (elements.volumeSlider) {
                    elements.volumeSlider.value = settings.volume;
                    // UIの数値表示などの更新が必要ならここで行う
                }
            }
            if (settings.audioOutputId) {
                restoreSavedSinkId(settings.audioOutputId);
            }

            if (typeof settings.groupAlbumArt === 'boolean') {
                state.groupAlbumArt = settings.groupAlbumArt;
            }
            if (typeof settings.isShuffled === 'boolean') {
                state.isShuffled = settings.isShuffled;
                if (elements.shuffleBtn) elements.shuffleBtn.classList.toggle('active', state.isShuffled);
            }
        }

        if (window.go || settings.libraryPath) {
            musicApi.loadLibrary();
        } else {
            const loadingOverlay = document.getElementById('loading-overlay');
            if (loadingOverlay) loadingOverlay.classList.add('hidden');
        }
    } catch (e) {
        console.error('Failed to load settings or library:', e);
        const loadingOverlay = document.getElementById('loading-overlay');
        if (loadingOverlay) loadingOverlay.classList.add('hidden');
    }

    electronAPI.send('app-ready');

    try {
        updateAudioDevices();
    } catch (e) {
        console.error('Failed to update audio devices:', e);
    }

    // デバイス接続/切断時にリストを自動更新 (Wails環境のみ)
    if (window.runtime && typeof window.runtime.EventsOn === 'function') {
        window.runtime.EventsOn('audio-devices-changed', () => {
            console.log('[AudioDevices] Device change detected via Go watcher');
            updateAudioDevices();
        });
    }

    console.log('[Renderer] Initializing IPC listeners...');
    initIPC({
        onFlacIndexProgress: (progress) => {
            const container = document.getElementById('flac-index-progress-container');
            const bar = document.getElementById('flac-index-progress-bar');
            const status = document.getElementById('flac-index-status');
            if (container && bar && status) {
                container.classList.remove('hidden');
                const percent = (progress.current / progress.total) * 100;
                bar.style.width = `${percent}%`;
                status.textContent = `解析中: ${progress.current} / ${progress.total} (${progress.path})`;
            }
        },
        onFlacIndexComplete: (total) => {
            const status = document.getElementById('flac-index-status');
            if (status) {
                status.textContent = `完了: ${total}個のファイルを解析しました。`;
                status.style.color = '#28a745';
            }
            setTimeout(() => {
                const container = document.getElementById('flac-index-progress-container');
                if (container) container.classList.add('hidden');
            }, 5000);
        }
    });
}

// 冗長で property 名が間違っていた古いヘルパー関数を削除
// 今後は playback-manager.js 内のロジックが使用されます。

initApp()
    .then(() => checkWails())
    .catch(err => console.error('App initialization failed:', err));

// ─── 音声情報ボタン 波形ホバーアニメーション ───────────────────────────
(function initWaveformAnimation() {
    const btn = document.getElementById('audio-info-btn');
    if (!btn) return;

    const wave1 = btn.querySelector('.wave-1');
    const wave2 = btn.querySelector('.wave-2');
    const wave3 = btn.querySelector('.wave-3');
    if (!wave1 || !wave2 || !wave3) return;

    // 各波の元のパス（始点・終点は絶対に変えない）
    const BASE = {
        w1: 'M 10 15 C 20 5, 40 5, 50 25 S 80 45, 90 35',
        w2: 'M 10 25 C 23 10, 40 15, 50 25 S 80 38, 90 25',
        w3: 'M 10 35 C 20 20, 40 20, 50 25 S 80 30, 90 15',
    };

    let rafId = null;
    let startTime = null;

    function buildPath1(t) {
        // 始点(10,15) 終点(90,35) 固定
        // Y=25を軸に対称: sin=+1→山型, sin=0→フラット, sin=-1→谷型（逆相）
        const amp = Math.sin(t * 8.4);
        const cy = 25 - 22 * amp; // +1時→3(上), -1時→47(下)
        const cy3 = 25 + 22 * amp; // +1時→47(下), -1時→3(上) ← 左右対称
        return `M 10 15 C 20 ${cy}, 40 ${cy}, 50 25 S 80 ${cy3}, 90 35`;
    }

    function buildPath2(t) {
        // 始点(10,25) 終点(90,25) 固定
        const amp = Math.sin(t * 5.7 + 0.4);
        const cy1 = 25 - 18 * amp; // +1時→7(上), -1時→43(下)
        const cy2 = 25 - 14 * amp;
        const cy3 = 25 + 16 * amp; // cy1と逆方向で対称
        return `M 10 25 C 23 ${cy1}, 40 ${cy2}, 50 25 S 80 ${cy3}, 90 25`;
    }

    function buildPath3(t) {
        // 始点(10,35) 終点(90,15) 固定
        const amp = Math.sin(t * 7.0 + 0.9);
        const cy = 25 - 18 * amp;
        const cy3 = 25 + 12 * amp;
        return `M 10 35 C 20 ${cy}, 40 ${cy}, 50 25 S 80 ${cy3}, 90 15`;
    }

    function animate(timestamp) {
        if (!startTime) startTime = timestamp;
        const t = (timestamp - startTime) / 1000;

        wave1.setAttribute('d', buildPath1(t));
        wave2.setAttribute('d', buildPath2(t));
        wave3.setAttribute('d', buildPath3(t));

        rafId = requestAnimationFrame(animate);
    }

    function stopAnimate() {
        if (rafId) { cancelAnimationFrame(rafId); rafId = null; }
        startTime = null;
        wave1.setAttribute('d', BASE.w1);
        wave2.setAttribute('d', BASE.w2);
        wave3.setAttribute('d', BASE.w3);
    }

    btn.addEventListener('mouseenter', () => {
        if (!rafId) rafId = requestAnimationFrame(animate);
    });
    btn.addEventListener('mouseleave', stopAnimate);
    btn.addEventListener('focus', () => { if (!rafId) rafId = requestAnimationFrame(animate); });
    btn.addEventListener('blur', stopAnimate);
})();
