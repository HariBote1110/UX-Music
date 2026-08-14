// src/renderer/js/features/sidecar.ts
/**
 * サイドカー（他デバイスへのフルスクリーン表示転送）のメニュー構築ロジック。
 * DOM に依存しない純粋関数として実装し、単体テストで振る舞いを保証する。
 */

import type { ContextMenuItem } from '../ui/utils.js';

export interface PairedRemoteDevice {
    deviceId: string;
    displayName: string;
    lastSeenAt: string;
    online: boolean;
}

export interface SidecarMenuCallbacks {
    openFullscreenView: () => void;
    setSidecarTargetDevice: (deviceId: string) => void;
}

const MAX_DEVICE_ID_DISPLAY_LENGTH = 16;

/** 長い deviceId をメニュー表示用に省略する。 */
export function truncateDeviceId(deviceId: string): string {
    if (deviceId.length <= MAX_DEVICE_ID_DISPLAY_LENGTH) return deviceId;
    const headLength = MAX_DEVICE_ID_DISPLAY_LENGTH - 1;
    return `${deviceId.slice(0, headLength)}…`;
}

/** デバイスの表示ラベルを決める（displayName 優先、無ければ deviceId を省略表示）。 */
export function formatDeviceLabel(device: PairedRemoteDevice): string {
    const name = (device.displayName ?? '').trim();
    if (name) return name;
    return truncateDeviceId(device.deviceId);
}

/**
 * ペアリング済みデバイス一覧からサイドカーメニュー項目を構築する。
 * 先頭は常に「このMacでフルスクリーン」、続いてサイドカー先デバイスのサブメニューを返す。
 */
export function buildSidecarMenuItems(
    devices: PairedRemoteDevice[],
    currentTarget: string,
    callbacks: SidecarMenuCallbacks,
): ContextMenuItem[] {
    const items: ContextMenuItem[] = [
        {
            label: 'このMacでフルスクリーン',
            action: () => callbacks.openFullscreenView(),
        },
    ];

    if (devices.length === 0) return items;

    const deviceItems: ContextMenuItem[] = devices.map((device) => {
        const isCurrent = currentTarget !== '' && currentTarget === device.deviceId;
        const baseLabel = formatDeviceLabel(device);
        const label = `${isCurrent ? '✓ ' : ''}${baseLabel}${device.online ? '' : ' (未接続)'}`;
        return {
            label,
            enabled: device.online,
            action: () => callbacks.setSidecarTargetDevice(isCurrent ? '' : device.deviceId),
        };
    });

    items.push({
        label: 'サイドカーに表示',
        submenu: deviceItems,
    });

    return items;
}
