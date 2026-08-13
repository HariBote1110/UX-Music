import { describe, expect, it } from 'vitest';
import { highestQualityYouTubeThumbnailURL, resolveRelayThumbnailCandidate } from './youtube-thumbnail.js';

describe('highestQualityYouTubeThumbnailURL', () => {
    it('builds the maxresdefault URL for a video ID', () => {
        expect(highestQualityYouTubeThumbnailURL('abc123')).toBe(
            'https://i.ytimg.com/vi/abc123/maxresdefault.jpg'
        );
    });
});

describe('resolveRelayThumbnailCandidate', () => {
    it('prefers the maxresdefault candidate when a video ID is known, ignoring song.artwork', () => {
        const song = { artwork: 'https://i.ytimg.com/vi/abc123/hqdefault.jpg' };
        expect(resolveRelayThumbnailCandidate(song, 'abc123')).toBe(
            'https://i.ytimg.com/vi/abc123/maxresdefault.jpg'
        );
    });

    it('falls back to a string song.artwork when no video ID is available', () => {
        const song = { artwork: 'https://example.com/custom-thumb.jpg' };
        expect(resolveRelayThumbnailCandidate(song, null)).toBe('https://example.com/custom-thumb.jpg');
    });

    it('falls back to song.artwork.thumbnail when no video ID is available', () => {
        const song = { artwork: { thumbnail: 'https://example.com/thumb.jpg', full: 'https://example.com/full.jpg' } };
        expect(resolveRelayThumbnailCandidate(song, undefined)).toBe('https://example.com/thumb.jpg');
    });

    it('falls back to song.artwork.full when thumbnail is missing and no video ID is available', () => {
        const song = { artwork: { full: 'https://example.com/full.jpg' } };
        expect(resolveRelayThumbnailCandidate(song, null)).toBe('https://example.com/full.jpg');
    });

    it('returns an empty string when neither a video ID nor usable artwork is available', () => {
        expect(resolveRelayThumbnailCandidate({}, null)).toBe('');
        expect(resolveRelayThumbnailCandidate(null, null)).toBe('');
    });
});
