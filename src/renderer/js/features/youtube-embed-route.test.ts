import { describe, expect, it } from 'vitest';
import {
    resolveYouTubePlaybackRoute,
    extractYouTubeVideoId,
    usesEmbedTimeSource,
} from './youtube-embed-route.js';

describe('resolveYouTubePlaybackRoute', () => {
    it('YouTube 以外の曲は設定値に関わらず local を返す', () => {
        expect(resolveYouTubePlaybackRoute('local', 'embed')).toBe('local');
        expect(resolveYouTubePlaybackRoute(undefined, 'embed')).toBe('local');
        expect(resolveYouTubePlaybackRoute('', 'stream')).toBe('local');
    });

    it('YouTube 曲かつ embed 設定なら embed を返す', () => {
        expect(resolveYouTubePlaybackRoute('youtube', 'embed')).toBe('embed');
        expect(resolveYouTubePlaybackRoute('youtube', ' EMBED ')).toBe('embed');
    });

    it('YouTube 曲で embed 以外の設定は従来どおり stream を返す', () => {
        expect(resolveYouTubePlaybackRoute('youtube', 'stream')).toBe('stream');
        expect(resolveYouTubePlaybackRoute('youtube', 'download')).toBe('stream');
        expect(resolveYouTubePlaybackRoute('youtube', undefined)).toBe('stream');
        expect(resolveYouTubePlaybackRoute('youtube', 42)).toBe('stream');
    });
});

describe('extractYouTubeVideoId', () => {
    it('watch URL から動画 ID を抽出する', () => {
        expect(extractYouTubeVideoId('https://www.youtube.com/watch?v=dQw4w9WgXcQ')).toBe('dQw4w9WgXcQ');
        expect(extractYouTubeVideoId('https://www.youtube.com/watch?list=PL123&v=dQw4w9WgXcQ&t=10s')).toBe('dQw4w9WgXcQ');
        expect(extractYouTubeVideoId('https://music.youtube.com/watch?v=dQw4w9WgXcQ')).toBe('dQw4w9WgXcQ');
    });

    it('短縮・shorts・embed・live URL から動画 ID を抽出する', () => {
        expect(extractYouTubeVideoId('https://youtu.be/dQw4w9WgXcQ')).toBe('dQw4w9WgXcQ');
        expect(extractYouTubeVideoId('https://youtu.be/dQw4w9WgXcQ?si=abc')).toBe('dQw4w9WgXcQ');
        expect(extractYouTubeVideoId('https://www.youtube.com/shorts/dQw4w9WgXcQ')).toBe('dQw4w9WgXcQ');
        expect(extractYouTubeVideoId('https://www.youtube.com/embed/dQw4w9WgXcQ')).toBe('dQw4w9WgXcQ');
        expect(extractYouTubeVideoId('https://www.youtube.com/live/dQw4w9WgXcQ')).toBe('dQw4w9WgXcQ');
    });

    it('不正な入力には null を返す', () => {
        expect(extractYouTubeVideoId('')).toBeNull();
        expect(extractYouTubeVideoId(undefined)).toBeNull();
        expect(extractYouTubeVideoId('https://example.com/watch?v=dQw4w9WgXcQ')).toBeNull();
        expect(extractYouTubeVideoId('https://www.youtube.com/watch?v=short')).toBeNull();
        expect(extractYouTubeVideoId('not a url')).toBeNull();
    });
});

describe('usesEmbedTimeSource', () => {
    it('embed 経路のときだけ埋め込みプレイヤーを時間ソースにする', () => {
        expect(usesEmbedTimeSource('embed')).toBe(true);
        expect(usesEmbedTimeSource('stream')).toBe(false);
        expect(usesEmbedTimeSource('local')).toBe(false);
    });
});
