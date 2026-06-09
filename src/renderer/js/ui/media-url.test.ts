import { describe, expect, it } from 'vitest';
import { buildSafeMediaPathURL } from './media-url.js';

describe('buildSafeMediaPathURL', () => {
    it('escapes reserved characters per path segment for Wails safe-media routes', () => {
        const got = buildSafeMediaPathURL('/Users/yuki/Music/a?b #100%.mp4');
        expect(got).toBe('/safe-media/Users/yuki/Music/a%3Fb%20%23100%25.mp4');
    });
});
