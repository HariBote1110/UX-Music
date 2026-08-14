import { describe, it, expect, vi } from 'vitest';
import { buildSidecarMenuItems, formatDeviceLabel } from './sidecar.js';

describe('formatDeviceLabel', () => {
    it('displayName があればそのまま使う', () => {
        expect(formatDeviceLabel({ deviceId: 'abc123', displayName: 'リビングiPhone', lastSeenAt: '', online: true }))
            .toBe('リビングiPhone');
    });

    it('displayName が空なら deviceId を使う', () => {
        expect(formatDeviceLabel({ deviceId: 'abc123', displayName: '', lastSeenAt: '', online: true }))
            .toBe('abc123');
    });

    it('deviceId が長い場合は適度に省略する', () => {
        const longId = 'a'.repeat(40);
        const label = formatDeviceLabel({ deviceId: longId, displayName: '', lastSeenAt: '', online: true });
        expect(label.length).toBeLessThan(longId.length);
        expect(label).toContain('…');
    });
});

describe('buildSidecarMenuItems', () => {
    const openFullscreenView = vi.fn();
    const setSidecarTargetDevice = vi.fn();

    it('デバイスが無い場合はローカルフルスクリーン項目のみ', () => {
        const items = buildSidecarMenuItems([], '', { openFullscreenView, setSidecarTargetDevice });
        expect(items[0].label).toBe('このMacでフルスクリーン');
        // デバイスが無いのでサイドカーの子項目は無いはず
        const deviceLabels = items.slice(1).flatMap(i => i.submenu?.map(s => s.label) ?? []);
        expect(deviceLabels.length).toBe(0);
    });

    it('オフラインのみのデバイスは無効化され、未接続ヒントが付く', () => {
        const items = buildSidecarMenuItems(
            [{ deviceId: 'dev1', displayName: 'iPhone', lastSeenAt: '', online: false }],
            '',
            { openFullscreenView, setSidecarTargetDevice },
        );
        const sidecarItem = items.find(i => i.submenu);
        expect(sidecarItem?.submenu?.[0].label).toContain('未接続');
        expect(sidecarItem?.submenu?.[0].enabled).toBe(false);
    });

    it('現在ターゲットのデバイスにはチェック印が付き、クリックでクリアされる', () => {
        const items = buildSidecarMenuItems(
            [{ deviceId: 'dev1', displayName: 'iPhone', lastSeenAt: '', online: true }],
            'dev1',
            { openFullscreenView, setSidecarTargetDevice },
        );
        const sidecarItem = items.find(i => i.submenu);
        const deviceItem = sidecarItem?.submenu?.[0];
        expect(deviceItem?.label).toContain('✓');
        deviceItem?.action?.();
        expect(setSidecarTargetDevice).toHaveBeenCalledWith('');
    });

    it('未選択のオンラインデバイスをクリックするとそのデバイスIDが設定される', () => {
        setSidecarTargetDevice.mockClear();
        const items = buildSidecarMenuItems(
            [{ deviceId: 'dev1', displayName: 'iPhone', lastSeenAt: '', online: true }],
            '',
            { openFullscreenView, setSidecarTargetDevice },
        );
        const sidecarItem = items.find(i => i.submenu);
        sidecarItem?.submenu?.[0].action?.();
        expect(setSidecarTargetDevice).toHaveBeenCalledWith('dev1');
    });

    it('先頭項目をクリックするとローカルフルスクリーンが開く', () => {
        openFullscreenView.mockClear();
        const items = buildSidecarMenuItems([], '', { openFullscreenView, setSidecarTargetDevice });
        items[0].action?.();
        expect(openFullscreenView).toHaveBeenCalled();
    });
});
