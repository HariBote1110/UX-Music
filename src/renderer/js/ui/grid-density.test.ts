import { describe, expect, it, vi } from 'vitest';

vi.mock('../core/bridge.js', () => ({
    musicApi: {
        saveSettings: vi.fn(),
    },
}));

describe('gridDensityToPx（設定 → px の純粋なマッピング）', () => {
    it('compact / standard / large をそれぞれ既定の px にマッピングする', async () => {
        const { gridDensityToPx } = await import('./grid-density.js');
        expect(gridDensityToPx('compact')).toBe(120);
        expect(gridDensityToPx('standard')).toBe(160);
        expect(gridDensityToPx('large')).toBe(220);
    });

    it('未知の値・未設定は standard (160px) にフォールバックする', async () => {
        const { gridDensityToPx } = await import('./grid-density.js');
        expect(gridDensityToPx(undefined)).toBe(160);
        expect(gridDensityToPx(null)).toBe(160);
        expect(gridDensityToPx('huge')).toBe(160);
        expect(gridDensityToPx(42)).toBe(160);
    });
});

describe('isGridDensity', () => {
    it('既知の3値のみ true を返す', async () => {
        const { isGridDensity } = await import('./grid-density.js');
        expect(isGridDensity('compact')).toBe(true);
        expect(isGridDensity('standard')).toBe(true);
        expect(isGridDensity('large')).toBe(true);
        expect(isGridDensity('other')).toBe(false);
        expect(isGridDensity(undefined)).toBe(false);
    });
});

describe('applyGridDensity', () => {
    it('--grid-item-min CSS 変数へ px 値を反映する', async () => {
        const { applyGridDensity, getCurrentGridDensity } = await import('./grid-density.js');
        applyGridDensity('large');
        expect(document.documentElement.style.getPropertyValue('--grid-item-min')).toBe('220px');
        expect(getCurrentGridDensity()).toBe('large');
    });
});
