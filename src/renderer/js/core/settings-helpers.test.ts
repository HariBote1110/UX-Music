import { describe, expect, it } from 'vitest';
import { normalizeSettings } from './settings-helpers.js';

describe('normalizeSettings', () => {
    it('returns empty object for null and undefined', () => {
        expect(normalizeSettings(null)).toEqual({});
        expect(normalizeSettings(undefined)).toEqual({});
    });

    it('returns empty object for non-object primitives and arrays', () => {
        expect(normalizeSettings(0)).toEqual({});
        expect(normalizeSettings('')).toEqual({});
        expect(normalizeSettings([])).toEqual({});
        expect(normalizeSettings([1, 2])).toEqual({});
    });

    it('returns the same object reference for plain objects', () => {
        const o = { audioOutputId: 'default', nested: { a: 1 } };
        expect(normalizeSettings(o)).toBe(o);
    });
});
