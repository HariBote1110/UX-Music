// AI 音声解析設定 UI のロジック。
// 設定モーダル内の "AI 音声解析 (Beta)" グループを駆動する。
//
// 関連 Wails API:
//   GetAudioEmbedStatus()                       → { stored, version, error? }
//   AnalyseLibraryAudioEmbeddings()             → { considered, skipped, analysed, failed, error? }
//   SearchTracksByMood(query, topK)             → [{ trackId, path, score }, ...]
//   event "audio-embed-progress"                → { done, total }

import { getWailsApp } from '../core/bridge.js';
import { showNotification, hideNotification } from '../ui/notification.js';

interface EmbedStatus {
    stored: number;
    version: string;
    error?: string;
}

interface AnalyseResponse {
    considered: number;
    skipped: number;
    analysed: number;
    failed: number;
    error?: string;
}

interface SearchHit {
    trackId: string;
    path: string;
    score: number;
}

let analyseInFlight = false;
let progressUnsubscribe: (() => void) | null = null;

function $<T extends HTMLElement>(id: string): T | null {
    return document.getElementById(id) as T | null;
}

function setProgress(done: number, total: number): void {
    const wrap = $('ai-audio-embed-progress-wrap');
    const fill = $<HTMLDivElement>('ai-audio-embed-progress-fill');
    const text = $('ai-audio-embed-progress-text');
    if (!wrap || !fill || !text) return;
    wrap.classList.remove('hidden');
    const pct = total > 0 ? Math.min(100, Math.round((done / total) * 100)) : 0;
    fill.style.width = `${pct}%`;
    text.textContent = total > 0 ? `${done} / ${total} 曲 (${pct}%)` : '準備中…';
}

function hideProgress(): void {
    $('ai-audio-embed-progress-wrap')?.classList.add('hidden');
}

function setStatus(text: string): void {
    const el = $('ai-audio-embed-status');
    if (el) el.textContent = text;
}

async function refreshStatus(): Promise<void> {
    const app = getWailsApp();
    if (!app?.GetAudioEmbedStatus) {
        setStatus('Wails ビルドが必要です。');
        return;
    }
    try {
        const s: EmbedStatus = await app.GetAudioEmbedStatus();
        if (s.error) {
            setStatus(`エラー: ${s.error}`);
            return;
        }
        setStatus(`解析済み ${s.stored} 曲 / モデル ${s.version}`);
    } catch (e) {
        setStatus(`状態取得失敗: ${(e as Error)?.message ?? String(e)}`);
    }
}

function subscribeProgress(): void {
    const runtime = (window as any).runtime;
    if (!runtime?.EventsOn) return;
    progressUnsubscribe?.();
    const off = runtime.EventsOn('audio-embed-progress', (payload: { done: number; total: number }) => {
        setProgress(payload?.done ?? 0, payload?.total ?? 0);
    });
    progressUnsubscribe = typeof off === 'function' ? off : null;
}

function unsubscribeProgress(): void {
    progressUnsubscribe?.();
    progressUnsubscribe = null;
}

async function onAnalyseClick(): Promise<void> {
    if (analyseInFlight) return;
    const app = getWailsApp();
    if (!app?.AnalyseLibraryAudioEmbeddings) {
        showNotification('Wails ビルドが必要です。');
        hideNotification(4000);
        return;
    }
    const btn = $<HTMLButtonElement>('ai-audio-embed-analyse-btn');
    if (btn) {
        btn.disabled = true;
        btn.textContent = '解析中…';
    }
    analyseInFlight = true;
    subscribeProgress();
    setProgress(0, 0);
    try {
        const res: AnalyseResponse = await app.AnalyseLibraryAudioEmbeddings();
        if (res.error) {
            showNotification(`解析エラー: ${res.error}`);
            hideNotification(8000);
        } else {
            showNotification(
                `解析完了 — 対象 ${res.considered} / 新規 ${res.analysed} / スキップ ${res.skipped} / 失敗 ${res.failed}`,
            );
            hideNotification(6000);
        }
    } catch (e) {
        showNotification(`解析失敗: ${(e as Error)?.message ?? String(e)}`);
        hideNotification(8000);
    } finally {
        analyseInFlight = false;
        unsubscribeProgress();
        hideProgress();
        if (btn) {
            btn.disabled = false;
            btn.textContent = 'ライブラリを解析';
        }
        await refreshStatus();
    }
}

function escapeHtml(s: string): string {
    return s.replace(/[&<>"']/g, ch =>
        ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch] as string,
    );
}

async function onSearchClick(): Promise<void> {
    const input = $<HTMLInputElement>('ai-audio-embed-search-input');
    const list = $('ai-audio-embed-search-results') as HTMLUListElement | null;
    if (!input || !list) return;
    const query = input.value.trim();
    if (!query) {
        showNotification('検索ワードを入力してください。');
        hideNotification(2500);
        return;
    }
    const app = getWailsApp();
    if (!app?.SearchTracksByMood) {
        showNotification('Wails ビルドが必要です。');
        hideNotification(4000);
        return;
    }
    list.innerHTML = '<li style="padding: 6px; color: #999;">検索中…</li>';
    try {
        const hits: SearchHit[] = await app.SearchTracksByMood(query, 20);
        if (!hits.length) {
            list.innerHTML = '<li style="padding: 6px; color: #999;">該当曲なし (まずライブラリ解析が必要かも)</li>';
            return;
        }
        list.innerHTML = hits
            .map(h => {
                const name = (h.path.split('/').pop() ?? h.path);
                return `<li style="padding: 6px 8px; border-bottom: 1px solid #2a2a2a; display: flex; justify-content: space-between; gap: 8px;">
                    <span style="overflow: hidden; text-overflow: ellipsis; white-space: nowrap;" title="${escapeHtml(h.path)}">${escapeHtml(name)}</span>
                    <span style="color: #4a9eff; font-variant-numeric: tabular-nums; flex-shrink: 0;">${h.score.toFixed(3)}</span>
                </li>`;
            })
            .join('');
    } catch (e) {
        list.innerHTML = `<li style="padding: 6px; color: #f66;">検索失敗: ${escapeHtml((e as Error)?.message ?? String(e))}</li>`;
    }
}

/** 設定モーダル初期化時に 1 度だけ呼ぶ */
export function initAiEmbedSettings(): void {
    const analyseBtn = $<HTMLButtonElement>('ai-audio-embed-analyse-btn');
    if (analyseBtn && !analyseBtn.dataset.listenerAttached) {
        analyseBtn.addEventListener('click', () => void onAnalyseClick());
        analyseBtn.dataset.listenerAttached = 'true';
    }
    const searchBtn = $<HTMLButtonElement>('ai-audio-embed-search-btn');
    if (searchBtn && !searchBtn.dataset.listenerAttached) {
        searchBtn.addEventListener('click', () => void onSearchClick());
        searchBtn.dataset.listenerAttached = 'true';
    }
    const searchInput = $<HTMLInputElement>('ai-audio-embed-search-input');
    if (searchInput && !searchInput.dataset.listenerAttached) {
        searchInput.addEventListener('keydown', ev => {
            if (ev.key === 'Enter') {
                ev.preventDefault();
                void onSearchClick();
            }
        });
        searchInput.dataset.listenerAttached = 'true';
    }
    void refreshStatus();
}
