import { describe, expect, it } from 'vitest';
import { DEFAULT_ARTWORK_URL } from './default-artwork.js';

describe('DEFAULT_ARTWORK_URL', () => {
  it('points at public default artwork (base-relative)', () => {
    expect(DEFAULT_ARTWORK_URL).toMatch(/assets\/default_artwork\.png$/);
  });
});
