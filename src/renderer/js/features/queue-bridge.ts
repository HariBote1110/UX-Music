// Pure logic for mirroring Go's native playback queue (server/app_queue.go,
// pkg/playqueue) into the renderer's `state` shape. No DOM, no bridge calls
// — see playback-manager.ts for the event listeners that call these with
// real dependencies (getSongById, musicApi, ...).
//
// Background: markdown/background-native-queue-plan.md Phase 1. The queue
// itself is Go's; this module only translates between its wire shape
// (queueStatePayload in app_queue.go: {items[], index, shuffled, loopMode,
// active}) and the renderer's existing state.playbackQueue/currentSongIndex/
// isShuffled/playbackMode so the existing UI code (ui-manager.ts's
// updatePlayingIndicators/renderQueueView) keeps working unmodified.

import { PLAYBACK_MODES } from '../core/state.js';
import type { Song } from '../../types/domain.js';

/** Raw queue item shape as emitted by queueItemPayload() in app_queue.go. */
export interface QueueItemPayload {
    id?: unknown;
    type?: unknown;
    path?: unknown;
    title?: unknown;
    artist?: unknown;
    album?: unknown;
    artworkId?: unknown;
}

/** Raw "queue-state-changed" / QueueGetState() payload shape. */
export interface QueueStatePayload {
    items?: unknown;
    index?: unknown;
    shuffled?: unknown;
    loopMode?: unknown;
    active?: unknown;
}

export interface MappedQueueState {
    playbackQueue: Song[];
    currentSongIndex: number;
    isShuffled: boolean;
    playbackMode: string;
}

const GO_LOOP_MODE_TO_JS: Record<string, string> = {
    off: PLAYBACK_MODES.NORMAL,
    all: PLAYBACK_MODES.LOOP_ALL,
    one: PLAYBACK_MODES.LOOP_ONE,
};

const JS_LOOP_MODE_TO_GO: Record<string, string> = {
    [PLAYBACK_MODES.NORMAL]: 'off',
    [PLAYBACK_MODES.LOOP_ALL]: 'all',
    [PLAYBACK_MODES.LOOP_ONE]: 'one',
};

/** Go LoopMode ("off"/"all"/"one") -> JS PLAYBACK_MODES. Unknown/missing defaults to NORMAL. */
export function fromGoLoopMode(goMode: unknown): string {
    if (typeof goMode !== 'string') return PLAYBACK_MODES.NORMAL;
    return GO_LOOP_MODE_TO_JS[goMode] ?? PLAYBACK_MODES.NORMAL;
}

/** JS PLAYBACK_MODES -> Go LoopMode. Unknown defaults to "off" (Go's LoopOff). */
export function toGoLoopMode(jsMode: unknown): string {
    if (typeof jsMode !== 'string') return 'off';
    return JS_LOOP_MODE_TO_GO[jsMode] ?? 'off';
}

/** Cycles normal -> loop-all -> loop-one -> normal, matching toggleLoopMode()'s modes array. */
export function nextLoopMode(currentJsMode: unknown): string {
    const modes = Object.values(PLAYBACK_MODES) as string[];
    const index = modes.indexOf(String(currentJsMode));
    return modes[(index + 1) % modes.length];
}

/**
 * Resolves a queue item payload back into a Song for the UI. Prefers the
 * full library entry (findSong), since queue items only carry the fields
 * app_queue.go's songMapToQueueItem needs (not artwork objects, sourceURL,
 * etc.) — falls back to a minimal Song reconstructed from the payload for
 * an item that (unexpectedly) isn't in the library.
 */
export function hydrateQueueItem(item: QueueItemPayload, findSong: (id: string) => Song | null | undefined): Song {
    const id = typeof item?.id === 'string' ? item.id : '';
    if (id) {
        const song = findSong(id);
        if (song) return song;
    }
    return {
        id,
        type: typeof item?.type === 'string' ? item.type : undefined,
        path: typeof item?.path === 'string' ? item.path : '',
        title: typeof item?.title === 'string' ? item.title : '',
        artist: typeof item?.artist === 'string' ? item.artist : '',
        album: typeof item?.album === 'string' ? item.album : '',
    };
}

/** Maps a full "queue-state-changed" / QueueGetState() payload into the renderer's queue-related state fields. */
export function mapQueueSnapshotToQueueState(
    payload: QueueStatePayload | null | undefined,
    findSong: (id: string) => Song | null | undefined,
): MappedQueueState {
    const items = Array.isArray(payload?.items) ? (payload!.items as QueueItemPayload[]) : [];
    return {
        playbackQueue: items.map((item) => hydrateQueueItem(item, findSong)),
        currentSongIndex: typeof payload?.index === 'number' ? payload!.index : -1,
        isShuffled: Boolean(payload?.shuffled),
        playbackMode: fromGoLoopMode(payload?.loopMode),
    };
}

/**
 * Mirrors buildSkipEvent()'s "was this actually a mid-song skip" heuristic
 * for the queue-advanced/reason:"user" case, where the renderer only has a
 * cached (possibly ~1s stale) currentTime/duration from Go status polling
 * rather than a live media element.
 */
export function shouldRecordQueueAdvancedSkip(currentTime: number, duration: number): boolean {
    return Number.isFinite(currentTime) && Number.isFinite(duration) && currentTime > 0 && duration > 0;
}
