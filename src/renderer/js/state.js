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
    currentlyViewedSongs: [],
    currentDetailView: { type: null, identifier: null },
    activeListView: 'track-view',
    artworksDir: '',
    preferredDeviceId: null,
    activeViewId: 'track-view',
    visualizerMode: 'active',
    isLightFlightMode: false,
    // ▼▼▼ ここからが修正箇所です ▼▼▼
    userPreferredVisualizerFps: 0, // LFモードに入る前のFPS設定を保持
    // ▲▲▲ ここまでが修正箇所です ▲▲▲
};

export const elements = {};

export function initElements() {
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
    elements.addNetworkFolderBtn = document.getElementById('add-network-folder-btn');
    elements.addYoutubeBtn = document.getElementById('add-youtube-btn');
    elements.setLibraryBtn = document.getElementById('set-library-btn');
    elements.loadingOverlay = document.getElementById('loading-overlay');
    elements.openSettingsBtn = document.getElementById('open-settings-btn');
    elements.settingsModalOverlay = document.getElementById('settings-modal-overlay');
    elements.settingsOkBtn = document.getElementById('settings-ok-btn');
    elements.youtubeModeRadios = document.querySelectorAll('input[name="youtube-mode"]');
    elements.youtubeQualityRadios = document.querySelectorAll('input[name="youtube-quality"]');
    elements.addYoutubePlaylistBtn = document.getElementById('add-youtube-playlist-btn');
    elements.notificationToast = document.getElementById('notification-toast');
    elements.notificationText = document.getElementById('notification-text');
    elements.lightFlightModeBtn = document.getElementById('light-flight-mode-btn');
    elements.lyricsView = document.getElementById('lyrics-view');
    elements.sidebarTabs = document.querySelectorAll('.sidebar-tab-btn');
    elements.sidebarTabContents = document.querySelectorAll('.sidebar-tab-content');
    elements.queueList = document.getElementById('queue-list');
    elements.hubLinkContainer = document.getElementById('hub-link-container');
    elements.dropZone = elements.mainContent;
}