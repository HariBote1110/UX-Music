// @ts-nocheck
/**
 * YouTube caption selection UI and add-to-library payload building.
 */

const electronAPI = window.electronAPI;

export const isWailsRuntime = () => window.go !== undefined || window.runtime !== undefined;

export function promptYouTubeCaptionSelection(videoInfo) {
    const tracks = Array.isArray(videoInfo?.captionTracks) ? videoInfo.captionTracks : [];
    if (tracks.length === 0) {
        return Promise.resolve({ captionMode: 'auto' });
    }

    return new Promise((resolve) => {
        const overlay = document.createElement('div');
        overlay.className = 'caption-selection-overlay';

        const dialog = document.createElement('div');
        dialog.className = 'caption-selection-dialog';

        const titleEl = document.createElement('h3');
        titleEl.className = 'caption-dialog-title';
        titleEl.textContent = '字幕トラックを選択';
        dialog.appendChild(titleEl);

        if (videoInfo?.title) {
            const videoTitleEl = document.createElement('p');
            videoTitleEl.className = 'caption-video-title';
            videoTitleEl.textContent = videoInfo.title;
            dialog.appendChild(videoTitleEl);
        }

        const buttonsEl = document.createElement('div');
        buttonsEl.className = 'caption-buttons';

        const closeWith = (result) => {
            overlay.remove();
            resolve(result);
        };

        const makeBtn = (label, modifierClass, onClick) => {
            const btn = document.createElement('button');
            btn.textContent = label;
            btn.className = `caption-btn${modifierClass ? ' ' + modifierClass : ''}`;
            btn.addEventListener('click', onClick);
            buttonsEl.appendChild(btn);
        };

        makeBtn('🔤 自動選択（推奨）', 'caption-btn--auto', () => closeWith({ captionMode: 'auto' }));
        makeBtn('🚫 字幕を使用しない', 'caption-btn--none', () => closeWith({ captionMode: 'none' }));

        tracks.forEach(track => {
            const lang = track?.languageCode || 'unknown';
            const label = track?.label || 'Unknown';
            const kind = track?.isAuto ? '自動生成' : '字幕';
            makeBtn(`[${lang}] ${label}  (${kind})`, '', () => closeWith({
                captionMode: 'language',
                captionLanguageCode: track?.languageCode || '',
                captionVssId: track?.vssId || '',
            }));
        });

        dialog.appendChild(buttonsEl);

        const cancelBtn = document.createElement('button');
        cancelBtn.textContent = 'キャンセル';
        cancelBtn.className = 'caption-btn caption-btn--cancel';
        cancelBtn.addEventListener('click', () => {
            console.log('[YouTube][UI] 字幕選択がキャンセルされました。');
            closeWith(null);
        });
        dialog.appendChild(cancelBtn);

        overlay.appendChild(dialog);
        document.body.appendChild(overlay);
        overlay.addEventListener('click', (e) => {
            if (e.target === overlay) {
                console.log('[YouTube][UI] 字幕選択がキャンセルされました。');
                closeWith(null);
            }
        });
    });
}

export async function buildYouTubeAddPayload(url) {
    const trimmedURL = typeof url === 'string' ? url.trim() : '';
    if (!trimmedURL) {
        return null;
    }

    if (!isWailsRuntime()) {
        return trimmedURL;
    }

    let payload = { url: trimmedURL, captionMode: 'auto' };
    try {
        console.log('[YouTube][UI] 動画情報を取得します:', trimmedURL);
        const info = await electronAPI.invoke('get-youtube-info', trimmedURL);
        const tracks = Array.isArray(info?.captionTracks) ? info.captionTracks : [];
        console.log('[YouTube][UI] 字幕候補数:', tracks.length, tracks);

        if (tracks.length > 0) {
            const selection = await promptYouTubeCaptionSelection(info);
            if (!selection) {
                return null;
            }
            payload = { ...payload, ...selection };
        }
    } catch (error) {
        console.error('[YouTube][UI] 動画情報取得に失敗。自動選択で続行します:', error);
    }

    return payload;
}
