import { describe, it, expect } from 'vitest';
import {
    resolveEmbedContainerId,
    resolveFullscreenMediaMode,
    FS_VIDEO_SLOT_ID,
    SIDEBAR_ARTWORK_ID,
} from './fullscreen-media.js';

describe('resolveEmbedContainerId', () => {
    it('embed 非稼働なら移動対象なし（null）', () => {
        expect(resolveEmbedContainerId({ fullscreenOpen: false, embedActive: false })).toBeNull();
        expect(resolveEmbedContainerId({ fullscreenOpen: true, embedActive: false })).toBeNull();
    });

    it('embed 稼働 × フルスクリーン開 → フルスクリーンの映像スロット', () => {
        expect(resolveEmbedContainerId({ fullscreenOpen: true, embedActive: true }))
            .toBe(FS_VIDEO_SLOT_ID);
    });

    it('embed 稼働 × フルスクリーン閉 → サイドバーのアートワークコンテナ', () => {
        expect(resolveEmbedContainerId({ fullscreenOpen: false, embedActive: true }))
            .toBe(SIDEBAR_ARTWORK_ID);
    });
});

describe('resolveFullscreenMediaMode', () => {
    it('embed 稼働中は映像モード', () => {
        expect(resolveFullscreenMediaMode(true)).toBe('video');
    });
    it('embed 非稼働時は静止画ジャケットモード', () => {
        expect(resolveFullscreenMediaMode(false)).toBe('artwork');
    });
});
