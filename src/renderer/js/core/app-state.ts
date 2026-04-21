import type { DetailViewState, PlayCountsMap, Song, SongWaitingContext } from '../../types/domain.js';

export const PLAYBACK_MODES = {
    NORMAL: 'normal',
    LOOP_ALL: 'loop-all',
    LOOP_ONE: 'loop-one',
} as const;

export interface AppState {
    library: Song[];
    libraryById: Map<string, Song>;
    libraryByPath: Map<string, Song>;
    albums: Map<string, unknown>;
    artists: Map<string, unknown>;
    playlists: unknown[];
    playCounts: PlayCountsMap;
    currentSongIndex: number;
    playbackQueue: Song[];
    originalQueueSource: Song[];
    playbackMode: string;
    isShuffled: boolean;
    /** Playback queue context while loudness analysis runs (shape used by ipc / playback-manager). */
    songWaitingForAnalysis: SongWaitingContext | null;
    mtpDevice: unknown | null;
    mtpStorages: unknown[] | null;
    currentLyrics: unknown;
    currentLyricsType: string | null;
    currentlyViewedSongIds: string[];
    currentDetailView: DetailViewState;
    activeListView: string;
    artworksDir: string;
    preferredDeviceId: string | null;
    activeViewId: string;
    visualizerMode: string;
    isLightFlightMode: boolean;
    userPreferredVisualizerFps: number;
    selectedSongIds: Set<string>;
    copiedSongIds: string[];
    groupAlbumArt: boolean;
    analysedQueue: { enabled: boolean; decayDays: number };
    equalizerSettings: {
        active: boolean;
        preamp: number;
        bands: number[];
        bass: number;
        mid: number;
        treble: number;
    };
    quiz: {
        isPlaying: boolean;
        currentQuestionIndex: number;
        score: number;
        questions: unknown[];
        startTime: number;
        timerInterval: ReturnType<typeof setInterval> | null;
        totalResponseTime: number;
        config: { length: number; difficulty: string };
    };
    audioContext: AudioContext | null;
    audioSource: MediaElementAudioSourceNode | null;
    gainNode: GainNode | null;
    analyser: AnalyserNode | null;
    dataArray: Uint8Array | null;
}

export const state: AppState = {
    library: [],
    libraryById: new Map(),
    libraryByPath: new Map(),
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
    mtpDevice: null,
    mtpStorages: null,
    currentLyrics: null,
    currentLyricsType: null,
    currentlyViewedSongIds: [],
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
