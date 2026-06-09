import type { Song, SongSkippedPayload } from '../../types/domain.js';

export interface SkipEventInput {
    analysedQueueEnabled: boolean;
    currentSongIndex: number;
    skippedSong: Song | null | undefined;
    currentTime: number;
    duration: number;
}

export function buildSkipEvent(input: SkipEventInput): SongSkippedPayload | null {
    if (!input.analysedQueueEnabled || input.currentSongIndex < 0) {
        return null;
    }
    if (!input.skippedSong || input.currentTime <= 0 || input.duration <= 0) {
        return null;
    }
    return {
        song: input.skippedSong,
        currentTime: input.currentTime,
    };
}
