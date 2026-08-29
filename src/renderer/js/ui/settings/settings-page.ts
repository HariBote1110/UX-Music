// src/renderer/js/ui/settings/settings-page.ts
//
// 設定ページの骨組み: 左ナビ＋右コンテンツの切り替え、検索フィルタ、開閉。
// 各セクションの中身（既存の項目 DOM）は index.html に静的に置かれており、
// このモジュールはナビ生成とセクションの表示/非表示・検索フィルタだけを担当する。
// EQ 描画のようなセクション固有の初期化は SectionDef.onShow に登録する。

import type { SectionId } from './section-ids.js';

export interface SectionDef {
    id: SectionId | string;
    title: string;
    /** セクションが表示されるたびに呼ばれる（EQ 再描画など、冪等な初期化を想定）。 */
    onShow?: () => void;
}

export interface SettingsPage {
    mount(): void;
    showSection(id: string): void;
    open(sectionId?: string): void;
    close(): void;
}

const AUDIO_SECTION_ALIAS: Record<string, string> = {
    audio: 'playback',
};

function resolveSectionId(sections: SectionDef[], requested: string | undefined): string {
    if (!requested) {
        return sections[0]?.id ?? '';
    }
    const aliased = AUDIO_SECTION_ALIAS[requested] ?? requested;
    return sections.some(s => s.id === aliased) ? aliased : (sections[0]?.id ?? '');
}

export function createSettingsPage(sections: SectionDef[]): SettingsPage {
    let mounted = false;
    let currentSectionId = sections[0]?.id ?? '';

    function overlay(): HTMLElement | null {
        return document.getElementById('settings-modal-overlay');
    }

    function navList(): HTMLElement | null {
        return document.getElementById('settings-nav-list');
    }

    function searchInput(): HTMLInputElement | null {
        return document.getElementById('settings-search-input') as HTMLInputElement | null;
    }

    function sectionEl(id: string): HTMLElement | null {
        return document.getElementById(`settings-section-${id}`);
    }

    function buildNav(): void {
        const list = navList();
        if (!list || list.dataset.built) return;
        list.innerHTML = '';
        for (const section of sections) {
            const btn = document.createElement('button');
            btn.type = 'button';
            btn.className = 'settings-nav-item';
            btn.textContent = section.title;
            btn.dataset.sectionId = String(section.id);
            btn.addEventListener('click', () => showSection(section.id));
            list.appendChild(btn);
        }
        list.dataset.built = 'true';
    }

    function showSection(id: string): void {
        currentSectionId = id;
        for (const section of sections) {
            const el = sectionEl(String(section.id));
            if (!el) continue;
            el.classList.toggle('hidden', section.id !== id);
        }
        navList()?.querySelectorAll<HTMLButtonElement>('.settings-nav-item').forEach(btn => {
            btn.classList.toggle('active', btn.dataset.sectionId === id);
        });
        const active = sections.find(s => s.id === id);
        active?.onShow?.();
    }

    function normalise(text: string): string {
        return text.trim().toLowerCase();
    }

    function applyFilter(): void {
        const input = searchInput();
        const query = normalise(input?.value ?? '');
        const items = document.querySelectorAll<HTMLElement>('.settings-content .setting-item');
        const sectionHasMatch = new Map<string, boolean>();

        items.forEach(item => {
            const matches = query === '' || normalise(item.textContent ?? '').includes(query);
            item.classList.toggle('setting-item--filtered-out', !matches);
            const section = item.closest<HTMLElement>('.settings-section');
            const sectionId = section?.dataset.section ?? '';
            sectionHasMatch.set(sectionId, (sectionHasMatch.get(sectionId) ?? false) || matches);
        });

        navList()?.querySelectorAll<HTMLButtonElement>('.settings-nav-item').forEach(btn => {
            const id = btn.dataset.sectionId ?? '';
            const hasMatch = query === '' || sectionHasMatch.get(id) === true;
            btn.classList.toggle('settings-nav-item--no-match', !hasMatch);
        });
    }

    function open(sectionId?: string): void {
        overlay()?.classList.remove('hidden');
        showSection(resolveSectionId(sections, sectionId ?? currentSectionId));
    }

    function close(): void {
        overlay()?.classList.add('hidden');
    }

    /**
     * 開発用クエリフラグ: `?settings=<sectionId>` で指定セクションを開いた状態で起動する。
     * ヘッドレスブラウザでの見た目確認専用で、本番動作には影響しない（パラメータが無ければ何もしない）。
     * MusicCenter テーマ切り替え（`&theme=mc`）は起動時の非同期テーマ復元より後に
     * 適用する必要があるため、init-settings.ts 側（loadRendererSettings の完了後）で処理する。
     */
    function applyDevQueryFlags(): void {
        try {
            const params = new URLSearchParams(location.search);
            const section = params.get('settings');
            if (section) {
                open(section);
            }
        } catch {
            // location が使えない環境（テスト等）では何もしない
        }
    }

    function mount(): void {
        if (mounted) return;
        mounted = true;
        buildNav();
        showSection(currentSectionId);

        searchInput()?.addEventListener('input', applyFilter);

        document.getElementById('settings-close-btn')?.addEventListener('click', close);

        document.addEventListener('keydown', e => {
            if (e.key === 'Escape' && !overlay()?.classList.contains('hidden')) {
                close();
            }
        });

        document.addEventListener('open-settings', ((e: CustomEvent<{ section?: string }>) => {
            open(e.detail?.section);
        }) as EventListener);

        applyDevQueryFlags();
    }

    return { mount, showSection, open, close };
}
