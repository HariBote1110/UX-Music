import { VirtualScroller } from './virtual-scroller.js';
import { formatTime } from './utils.js';
import { getAlbumSongs } from '../core/library-model.js';
import { showNotification, hideNotification } from './notification.js';

let currentModal: HTMLElement | null = null;
let currentScroller: InstanceType<typeof VirtualScroller> | null = null;

const ITEM_HEIGHT = 52;

/**
 * アルバムの曲順を番号入力で手動設定するモーダルを開く
 */
export function openAlbumOrderEditor(albumKey: string, album: Record<string, unknown>) {
    closeAlbumOrderEditor();

    const songs = getAlbumSongs(album);
    if (songs.length === 0) return;

    // 作業用コピー（元データを汚さない）
    const workingSongs = songs.map((s, i) => ({
        ...s,
        _editOrder: s.customOrder ?? (i + 1),
    }));

    // ── オーバーレイ ──────────────────────────────────────────
    const overlay = document.createElement('div');
    overlay.className = 'album-order-overlay';
    overlay.addEventListener('pointerdown', (e) => {
        if (e.target === overlay) closeAlbumOrderEditor();
    });

    // ── モーダル本体 ──────────────────────────────────────────
    const modal = document.createElement('div');
    modal.className = 'album-order-modal';

    // ヘッダー
    const header = document.createElement('div');
    header.className = 'album-order-modal__header';
    header.innerHTML = `
        <h2 class="album-order-modal__title">曲順を編集</h2>
        <p class="album-order-modal__subtitle">${escapeHtml(String(album.title ?? ''))} — 番号を入力して確定してください</p>
    `;

    // リスト（仮想スクロール）
    const listEl = document.createElement('div');
    listEl.className = 'album-order-modal__list';

    // フッター
    const footer = document.createElement('div');
    footer.className = 'album-order-modal__footer';

    const resetBtn = document.createElement('button');
    resetBtn.className = 'album-order-modal__btn album-order-modal__btn--secondary';
    resetBtn.textContent = 'リセット';
    resetBtn.addEventListener('click', () => {
        workingSongs.forEach((s, i) => { s._editOrder = i + 1; });
        scroller.updateData([...workingSongs]);
    });

    const cancelBtn = document.createElement('button');
    cancelBtn.className = 'album-order-modal__btn album-order-modal__btn--secondary';
    cancelBtn.textContent = 'キャンセル';
    cancelBtn.addEventListener('click', closeAlbumOrderEditor);

    const confirmBtn = document.createElement('button');
    confirmBtn.className = 'album-order-modal__btn album-order-modal__btn--primary';
    confirmBtn.textContent = '確定';
    confirmBtn.addEventListener('click', () => saveOrder(albumKey, workingSongs, confirmBtn));

    footer.appendChild(resetBtn);
    footer.appendChild(cancelBtn);
    footer.appendChild(confirmBtn);

    modal.appendChild(header);
    modal.appendChild(listEl);
    modal.appendChild(footer);
    overlay.appendChild(modal);
    document.body.appendChild(overlay);

    // ── 仮想スクローラー ──────────────────────────────────────
    const scroller = new VirtualScroller({
        element: listEl,
        data: [...workingSongs],
        itemHeight: ITEM_HEIGHT,
        buffer: 8,
        renderItem: (rawSong: unknown, _index: number) => {
            const song = rawSong as Record<string, unknown>;
            const row = document.createElement('div');
            row.className = 'album-order-row';

            const numInput = document.createElement('input');
            numInput.type = 'number';
            numInput.min = '1';
            numInput.className = 'album-order-row__input';
            numInput.value = String(song._editOrder ?? '');
            numInput.addEventListener('change', () => {
                const v = parseInt(numInput.value, 10);
                if (!Number.isNaN(v) && v >= 1) {
                    song._editOrder = v;
                }
            });
            // フォーカス時に全選択（入力しやすく）
            numInput.addEventListener('focus', () => numInput.select());

            const info = document.createElement('div');
            info.className = 'album-order-row__info';
            info.innerHTML = `
                <span class="album-order-row__title">${escapeHtml(String(song.title ?? ''))}</span>
                <span class="album-order-row__meta">${escapeHtml(String(song.artist ?? ''))} · ${formatTime(Number(song.duration ?? 0))}</span>
            `;

            row.appendChild(numInput);
            row.appendChild(info);
            return row;
        },
    });

    currentScroller = scroller;
    currentModal = overlay;

    // ESC で閉じる
    const onKeydown = (e: KeyboardEvent) => {
        if (e.key === 'Escape') closeAlbumOrderEditor();
    };
    overlay.dataset.keydownRef = 'true';
    document.addEventListener('keydown', onKeydown);
    // クリーンアップ時に解除するために保持
    (overlay as any)._cleanup = () => document.removeEventListener('keydown', onKeydown);
}

async function saveOrder(albumKey: string, workingSongs: Record<string, unknown>[], btn: HTMLButtonElement) {
    btn.disabled = true;
    btn.textContent = '保存中...';

    // 入力された番号でソートして確定順序を決定
    const sorted = [...workingSongs].sort((a, b) => (a._editOrder as number) - (b._editOrder as number));
    const orderedIds = sorted.map(s => s.id as string).filter(Boolean);

    try {
        await window.go.server.App.SaveAlbumSongOrder(albumKey, orderedIds);
        showNotification('曲順を保存しました。');
        hideNotification(2500);
        closeAlbumOrderEditor();
    } catch (err) {
        console.error('[AlbumOrderEditor] save failed:', err);
        btn.disabled = false;
        btn.textContent = '確定';
        showNotification(`保存に失敗しました: ${err}`);
        hideNotification(4000);
    }
}

export function closeAlbumOrderEditor() {
    if (currentScroller) {
        currentScroller.destroy();
        currentScroller = null;
    }
    if (currentModal) {
        (currentModal as any)._cleanup?.();
        currentModal.remove();
        currentModal = null;
    }
}

function escapeHtml(str: string): string {
    return str.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}
