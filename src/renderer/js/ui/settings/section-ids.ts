// src/renderer/js/ui/settings/section-ids.ts
//
// 設定ページのセクション ID 一覧。SectionId を section-registry / settings-keys /
// 各 sections/*.ts の間で共有する単一の型定義源。

export const SECTION_IDS = [
    'general',
    'playback',
    'library',
    'appearance',
    'youtube',
    'integration',
    'ai',
    'advanced',
] as const;

export type SectionId = (typeof SECTION_IDS)[number];
