import { describe, expect, it } from 'vitest';
import {
    BAND_FREQUENCIES,
    EQ_PRESETS,
    MAX_DB,
    MIN_DB,
    dbToY,
    freqToX,
    legacyBandsFromSimpleControls,
    migrateLegacySimpleSettings,
    nearestBandIndex,
    presetBands,
    xToFreq,
    yToDb,
} from './eq-maths.js';

describe('freqToX / xToFreq', () => {
    it('maps the minimum frequency to x=0 and the maximum frequency to x=width', () => {
        const width = 400;
        expect(freqToX(20, width)).toBeCloseTo(0, 5);
        expect(freqToX(20000, width)).toBeCloseTo(width, 5);
    });

    it('is the inverse of xToFreq', () => {
        const width = 400;
        for (const freq of BAND_FREQUENCIES) {
            const x = freqToX(freq, width);
            expect(xToFreq(x, width)).toBeCloseTo(freq, 3);
        }
    });
});

describe('dbToY / yToDb', () => {
    it('maps +MAX_DB to the top (y=0) and -MIN_DB to the bottom (y=height)', () => {
        const height = 200;
        expect(dbToY(MAX_DB, height)).toBeCloseTo(0, 5);
        expect(dbToY(MIN_DB, height)).toBeCloseTo(height, 5);
        expect(dbToY(0, height)).toBeCloseTo(height / 2, 5);
    });

    it('is the inverse of yToDb', () => {
        const height = 200;
        for (const db of [-12, -6, 0, 3, 12]) {
            expect(yToDb(dbToY(db, height), height)).toBeCloseTo(db, 5);
        }
    });
});

describe('nearestBandIndex', () => {
    const width = 400;
    const height = 200;
    const bands = BAND_FREQUENCIES.map(() => 0);

    it('returns the index of the band whose point is within the hit radius', () => {
        const targetIndex = 3;
        const point = {
            x: freqToX(BAND_FREQUENCIES[targetIndex], width),
            y: dbToY(bands[targetIndex], height),
        };
        expect(nearestBandIndex(point.x, point.y, width, height, bands)).toBe(targetIndex);
    });

    it('returns -1 when no point is within the hit radius', () => {
        expect(nearestBandIndex(-1000, -1000, width, height, bands)).toBe(-1);
    });
});

describe('presetBands', () => {
    it('returns a copy of a known preset', () => {
        const flat = presetBands('Flat');
        expect(flat).toEqual([0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        flat![0] = 99;
        expect(presetBands('Flat')).toEqual([0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    });

    it('returns null for an unknown preset', () => {
        expect(presetBands('NotARealPreset')).toBeNull();
    });

    it('exposes all preset names via EQ_PRESETS', () => {
        expect(Object.keys(EQ_PRESETS)).toContain('Rock');
    });
});

describe('legacyBandsFromSimpleControls', () => {
    it('folds bass/mid/treble adjustments into a 10-band array, matching the historic weighting', () => {
        const bands = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        const result = legacyBandsFromSimpleControls(bands, 4, 2, 1);
        expect(result).toEqual([4, 4, 2, 1, 2, 2, 1, 0.5, 1, 1]);
    });

    it('does not mutate the input bands array', () => {
        const bands = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        legacyBandsFromSimpleControls(bands, 4, 2, 1);
        expect(bands).toEqual([0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    });

    it('is a no-op when bass/mid/treble are all zero', () => {
        const bands = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
        expect(legacyBandsFromSimpleControls(bands, 0, 0, 0)).toEqual(bands);
    });
});

describe('migrateLegacySimpleSettings', () => {
    it('folds a legacy bass/mid/treble-only setting into bands, once', () => {
        const migrated = migrateLegacySimpleSettings({
            bands: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            bass: 3,
            mid: 0,
            treble: -2,
        });
        expect(migrated).toEqual({
            bands: legacyBandsFromSimpleControls([0, 0, 0, 0, 0, 0, 0, 0, 0, 0], 3, 0, -2),
            bass: 0,
            mid: 0,
            treble: 0,
        });
    });

    it('returns null when bass/mid/treble are already zero (nothing to migrate)', () => {
        expect(
            migrateLegacySimpleSettings({ bands: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], bass: 0, mid: 0, treble: 0 }),
        ).toBeNull();
    });
});
