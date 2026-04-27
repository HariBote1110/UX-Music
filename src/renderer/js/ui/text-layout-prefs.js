// 曲一覧のタイトル列が極端に狭くならないよう、最小幅を CSS 変数で調整する。

const TITLE_LIST_MIN_KEY = 'ux-music-title-list-min-width-px';

export function getTitleListMinWidthPx() {
    try {
        const v = parseInt(localStorage.getItem(TITLE_LIST_MIN_KEY) || '0', 10);
        if (Number.isNaN(v) || v < 0) return 0;
        return Math.min(400, v);
    } catch {
        return 0;
    }
}

export function applyTitleListMinWidthPref() {
    const px = getTitleListMinWidthPx();
    document.documentElement.style.setProperty(
        '--song-title-list-min-px',
        px > 0 ? `${px}px` : '0px'
    );
}

export function persistTitleListMinWidthPx(px) {
    const clamped = Math.max(0, Math.min(400, px | 0));
    localStorage.setItem(TITLE_LIST_MIN_KEY, String(clamped));
    applyTitleListMinWidthPref();
}

export function formatTitleListMinWidthLabel(px) {
    if (!px) return '0 px（自動）';
    return `${px} px`;
}
