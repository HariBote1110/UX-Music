// src/renderer/js/ui/settings/settings-keys.ts
//
// 旧「OK で一括保存」ハンドラ（init-settings.ts, 旧版）が集めていた設定キーの一覧と、
// 新しい設定ページでそのキーをどのセクションが即時保存として引き継いだかの対応表。
// 移行漏れがないことをテスト（section-registry.test.ts）で機械的に確認するために存在する。

import type { SectionId } from './section-ids.js';

/** 旧 OK ボタン・旧デバイス管理モーダルが保存していた設定キー（移行対象の全量）。 */
export const LEGACY_SETTING_KEYS = [
    'youtubePlaybackMode',
    'youtubeDownloadQuality',
    'importMode',
    'cdRipMode',
    'visualizerMode',
    'analysedQueue',
    'enableEasterEggs',
    'lyricsSyncModelConsent',
    'uiTheme',
    'hiddenDeviceIds',
] as const;

export type LegacySettingKey = (typeof LEGACY_SETTING_KEYS)[number];

/** 各キーを即時保存するセクション。新規追加した gridDensity 等は対象外（旧キーではないため）。 */
export const SETTING_KEY_SECTIONS: Record<LegacySettingKey, SectionId> = {
    youtubePlaybackMode: 'youtube',
    youtubeDownloadQuality: 'youtube',
    importMode: 'library',
    cdRipMode: 'library',
    visualizerMode: 'appearance',
    analysedQueue: 'general',
    enableEasterEggs: 'general',
    lyricsSyncModelConsent: 'ai',
    uiTheme: 'appearance',
    hiddenDeviceIds: 'playback',
};
