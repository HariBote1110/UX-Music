import { describe, expect, it, vi } from 'vitest';
import { applyShuffleSetting, normalizeSettings } from './settings-helpers.js';

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

describe('applyShuffleSetting', () => {
    it('reflects a true isShuffled value into state and toggles the shuffle button active', () => {
        const state = { isShuffled: false } as { isShuffled: boolean };
        const classListToggle = vi.fn();
        const elements = { shuffleBtn: { classList: { toggle: classListToggle } } } as unknown as {
            shuffleBtn: HTMLElement | null;
        };

        applyShuffleSetting({ isShuffled: true }, state, elements);

        expect(state.isShuffled).toBe(true);
        expect(classListToggle).toHaveBeenCalledWith('active', true);
    });

    it('reflects a false isShuffled value into state and toggles the shuffle button inactive', () => {
        const state = { isShuffled: true } as { isShuffled: boolean };
        const classListToggle = vi.fn();
        const elements = { shuffleBtn: { classList: { toggle: classListToggle } } } as unknown as {
            shuffleBtn: HTMLElement | null;
        };

        applyShuffleSetting({ isShuffled: false }, state, elements);

        expect(state.isShuffled).toBe(false);
        expect(classListToggle).toHaveBeenCalledWith('active', false);
    });

    it('leaves state untouched when isShuffled is not a boolean', () => {
        const state = { isShuffled: true } as { isShuffled: boolean };
        const classListToggle = vi.fn();
        const elements = { shuffleBtn: { classList: { toggle: classListToggle } } } as unknown as {
            shuffleBtn: HTMLElement | null;
        };

        applyShuffleSetting({}, state, elements);

        expect(state.isShuffled).toBe(true);
        expect(classListToggle).not.toHaveBeenCalled();
    });

    it('does not throw when shuffleBtn element is missing', () => {
        const state = { isShuffled: false } as { isShuffled: boolean };
        const elements = { shuffleBtn: null } as { shuffleBtn: HTMLElement | null };

        expect(() => applyShuffleSetting({ isShuffled: true }, state, elements)).not.toThrow();
        expect(state.isShuffled).toBe(true);
    });
});
