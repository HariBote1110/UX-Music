export const PLAYBACK_MODES = {
    NORMAL: 'normal',
    LOOP_ALL: 'loop-all',
    LOOP_ONE: 'loop-one',
};

export const state = {
    library: [],
    albums: new Map(),
    artists: new Map(),
    playlists: [],
    playCounts: {},
    currentSongIndex: -1,
    playbackQueue: [],
    originalQueueSource: [],
    playbackMode: PLAYBACK_MODES.NORMAL,
    isShuffled: false,
    songWaitingForAnalysis: null,
    currentLyrics: null,
    currentLyricsType: null, // ★★★ 追加: 'txt', 'lrc', または null ★★★
    currentlyViewedSongs: [],
    currentDetailView: { type: null, identifier: null },
    activeListView: 'track-view',
    artworksDir: '',
    preferredDeviceId: null,
    activeViewId: 'track-view',
    visualizerMode: 'active',
    isLightFlightMode: false,
    userPreferredVisualizerFps: 0,
    selectedSongIds: new Set(),
    copiedSongIds: [],
    groupAlbumArt: false,
    analysedQueue: {
        enabled: false,
        decayDays: 7, // スコアの有効期間（日数）
    },
    equalizerSettings: {
        active: false, // EQが有効かどうか
        preamp: 0,
        bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], // 10バンドに変更
        bass: 0,
        mid: 0,
        treble: 0
    }
};

// ... (elements and initElements remain the same) ...
export const elements = {};

export function initElements() {
    // Existing elements
    elements.mainContent = document.getElementById('main-content');
    elements.nowPlayingArtworkContainer = document.getElementById('now-playing-artwork-container');
    elements.nowPlayingTitle = document.getElementById('now-playing-title');
    elements.nowPlayingArtist = document.getElementById('now-playing-artist');
    elements.playPauseBtn = document.getElementById('play-pause-btn');
    elements.prevBtn = document.getElementById('prev-btn');
    elements.nextBtn = document.getElementById('next-btn');
    elements.shuffleBtn = document.getElementById('shuffle-btn');
    elements.loopBtn = document.getElementById('loop-btn');
    elements.progressBar = document.getElementById('progress-bar');
    elements.currentTimeEl = document.getElementById('current-time');
    elements.totalDurationEl = document.getElementById('total-duration');
    elements.volumeSlider = document.getElementById('volume-slider');
    elements.volumeIcon = document.getElementById('volume-icon');
    elements.deviceSelectButton = document.getElementById('device-select-button');
    elements.devicePopup = document.getElementById('device-popup');
    elements.navLinks = document.querySelectorAll('.nav-link');
    elements.modalOverlay = document.getElementById('modal-overlay');
    elements.modalTitle = document.querySelector('#modal h3');
    elements.modalInput = document.getElementById('modal-input');
    elements.modalOkBtn = document.getElementById('modal-ok-btn');
    elements.modalCancelBtn = document.getElementById('modal-cancel-btn');
    elements.loadingOverlay = document.getElementById('loading-overlay');
    elements.openSettingsBtn = document.getElementById('open-settings-btn');
    elements.settingsModalOverlay = document.getElementById('settings-modal-overlay');
    elements.settingsOkBtn = document.getElementById('settings-ok-btn');
    elements.youtubeModeRadios = document.querySelectorAll('input[name="youtube-mode"]');
    elements.youtubeQualityRadios = document.querySelectorAll('input[name="youtube-quality"]');
    elements.notificationToast = document.getElementById('notification-toast');
    elements.notificationText = document.getElementById('notification-text');
    elements.lightFlightModeBtn = document.getElementById('light-flight-mode-btn');
    elements.lyricsView = document.getElementById('lyrics-view'); // ★★★ Ensure this exists ★★★
    elements.sidebarTabs = document.querySelectorAll('.sidebar-tab-btn');
    elements.sidebarTabContents = document.querySelectorAll('.sidebar-tab-content');
    elements.queueList = document.getElementById('queue-list');
    elements.hubLinkContainer = document.getElementById('hub-link-container');
    elements.dropZone = elements.mainContent;

    // New Normalize View Elements
    elements.normalizeView = document.getElementById('normalize-view');
    elements.normalizeViewBtn = document.getElementById('normalize-view-btn');

    // Equalizer elements
    elements.equalizerContainer = document.getElementById('equalizer-container');
    elements.equalizerView = document.getElementById('equalizer-view');

    // MTPデバイスUI (前回追加分)
    elements.mtpDeviceButton = document.getElementById('mtp-device-button');
    elements.mtpDevicePopup = document.getElementById('mtp-device-popup');
    elements.mtpDeviceName = document.getElementById('mtp-device-name');
    elements.mtpStorageUsed = document.getElementById('mtp-storage-used');
    elements.mtpStorageLabel = document.getElementById('mtp-storage-label');
    
    // ▼▼▼ 新規追加 (MTPポップアップ内ボタン ＋ 転送ビュー) ▼▼▼
    elements.mtpTransferQueueBtn = document.getElementById('mtp-transfer-queue-btn');
    elements.mtpEjectBtn = document.getElementById('mtp-eject-btn');

    // 転送ビュー本体
    elements.mtpTransferView = document.getElementById('mtp-transfer-view');
    elements.mtpTransferCloseBtn = document.getElementById('mtp-transfer-close-btn');
    elements.mtpTransferDeviceName = document.getElementById('mtp-transfer-device-name');
    
    // 転送ビュー - ペイン
    elements.mtpTransferSourceList = document.getElementById('mtp-transfer-source-list');
    elements.mtpTransferDeviceList = document.getElementById('mtp-transfer-device-list');
    
    // 転送ビュー - アクション
    elements.mtpTransferStartBtn = document.getElementById('mtp-transfer-start-btn');
    elements.mtpTransferProgressContainer = document.getElementById('mtp-transfer-progress-container');
    elements.mtpTransferProgressLabel = document.getElementById('mtp-transfer-progress-label');
    elements.mtpTransferProgressBar = document.getElementById('mtp-transfer-progress-bar');
    // ▲▲▲ 新規追加 ▲▲▲
}