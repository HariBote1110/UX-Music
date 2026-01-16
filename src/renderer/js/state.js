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
    currentLyricsType: null,
    currentlyViewedSongs: [],
    currentDetailView: { type: null, identifier: null, data: null },
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
        decayDays: 7,
    },
    equalizerSettings: {
        active: false,
        preamp: 0,
        bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        bass: 0,
        mid: 0,
        treble: 0
    },
    quiz: {
        isPlaying: false,
        currentQuestionIndex: 0,
        score: 0,
        questions: [],
        startTime: 0,
        timerInterval: null,
        totalResponseTime: 0,
        config: { length: 10, difficulty: 'normal' }
    },
    audioContext: null,
    audioSource: null,
    gainNode: null,
    analyser: null,
    dataArray: null,
};

export const elements = {};

export function initElements() {
    // Main Containers
    elements.mainContent = document.getElementById('main-content');
    elements.musicList = document.getElementById('main-content');

    elements.nowPlayingArtworkContainer = document.getElementById('now-playing-artwork-container');

    // ▼▼▼ 修正: コンテナ要素自体を取得するように戻しました ▼▼▼
    elements.nowPlayingTitle = document.getElementById('now-playing-title');
    elements.nowPlayingArtist = document.getElementById('now-playing-artist');
    // ▲▲▲ 修正完了 ▲▲▲

    // Playback Controls
    elements.playPauseBtn = document.getElementById('play-pause-btn');
    elements.prevBtn = document.getElementById('prev-btn');
    elements.nextBtn = document.getElementById('next-btn');
    elements.shuffleBtn = document.getElementById('shuffle-btn');
    elements.loopBtn = document.getElementById('loop-btn');
    elements.progressBar = document.getElementById('progress-bar');
    elements.currentTimeEl = document.getElementById('current-time');
    elements.totalDurationEl = document.getElementById('total-duration');
    elements.volumeSlider = document.getElementById('volume-slider');
    elements.volumeIcon = document.getElementById('volume-icon-btn');
    elements.volumeRange = document.getElementById('volume-slider');

    // Devices & Navigation
    elements.deviceSelectButton = document.getElementById('device-select-button');
    elements.devicePopup = document.getElementById('device-popup');
    elements.navLinks = document.querySelectorAll('.nav-link');

    // Modal
    elements.modalOverlay = document.getElementById('modal-overlay');
    elements.modalTitle = document.querySelector('#modal h3');
    elements.modalInput = document.getElementById('modal-input');
    elements.modalOkBtn = document.getElementById('modal-ok-btn');
    elements.modalCancelBtn = document.getElementById('modal-cancel-btn');
    elements.loadingOverlay = document.getElementById('loading-overlay');

    // Settings
    elements.openSettingsBtn = document.getElementById('open-settings-btn');
    elements.settingsModalOverlay = document.getElementById('settings-modal-overlay');
    elements.settingsOkBtn = document.getElementById('settings-ok-btn');
    elements.notificationToast = document.getElementById('notification-toast');
    elements.notificationText = document.getElementById('notification-text');
    elements.lightFlightModeBtn = document.getElementById('light-flight-mode-btn');

    // Sidebar
    elements.lyricsView = document.getElementById('lyrics-view');
    elements.sidebarTabs = document.querySelectorAll('.sidebar-tab-btn');
    elements.sidebarTabContents = document.querySelectorAll('.sidebar-tab-content');
    elements.queueList = document.getElementById('queue-list');
    elements.hubLinkContainer = document.getElementById('hub-link-container');
    elements.dropZone = document.body;

    // Normalize View Elements
    elements.normalizeView = document.getElementById('normalize-view');
    elements.normalizeViewBtn = document.getElementById('normalize-view-btn');
    elements.normalizeDropZone = document.getElementById('normalize-drop-zone');
    elements.normalizeFileList = document.getElementById('normalize-file-list');
    elements.normalizeAnalyzeBtn = document.getElementById('normalize-analyze-btn');
    elements.normalizeApplyBtn = document.getElementById('normalize-apply-btn');
    elements.normalizeProgressBar = document.getElementById('normalize-progress-bar');
    elements.normalizeProgressLabel = document.getElementById('normalize-progress-label');
    elements.normalizeProgressContainer = document.getElementById('normalize-progress-container');

    // Equalizer elements
    elements.equalizerContainer = document.getElementById('equalizer-container');
    elements.equalizerView = document.getElementById('equalizer-view');

    // MTP Device
    elements.mtpDeviceButton = document.getElementById('mtp-device-button');
    elements.mtpDevicePopup = document.getElementById('mtp-device-popup');
    elements.mtpDeviceName = document.getElementById('mtp-device-name');
    elements.mtpStorageUsed = document.getElementById('mtp-storage-used');
    elements.mtpStorageLabel = document.getElementById('mtp-storage-label');
    elements.mtpTransferQueueBtn = document.getElementById('mtp-transfer-queue-btn');
    elements.mtpEjectBtn = document.getElementById('mtp-eject-btn');
    elements.mtpBrowseStorageBtn = document.getElementById('mtp-browse-storage-btn');

    // MTP Transfer View
    elements.mtpTransferView = document.getElementById('mtp-transfer-view');
    elements.mtpTransferCloseBtn = document.getElementById('mtp-transfer-close-btn');
    elements.mtpTransferDeviceName = document.getElementById('mtp-transfer-device-name');
    elements.mtpTransferSourceList = document.getElementById('mtp-transfer-source-list');
    elements.mtpTransferDeviceList = document.getElementById('mtp-transfer-device-list');
    elements.mtpTransferStartBtn = document.getElementById('mtp-transfer-start-btn');
    elements.mtpTransferProgressContainer = document.getElementById('mtp-transfer-progress-container');
    elements.mtpTransferProgressLabel = document.getElementById('mtp-transfer-progress-label');
    elements.mtpTransferProgressBar = document.getElementById('mtp-transfer-progress-bar');

    // Other Views
    elements.lrcEditorView = document.getElementById('lrc-editor-view');
    elements.quizView = document.getElementById('quiz-view');
}