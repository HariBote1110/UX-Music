// 詳細ビュー共通の丸い「戻る」ボタン

import { canGoBack, goBack } from '../core/navigation.js';

/**
 * ナビゲーション履歴があるとき、詳細ビューの左上に丸い「‹」戻るボタンを差し込む。
 * すべての詳細ビュー（アルバム／アーティスト／プレイリスト）で共用する。
 */
export function prependDetailBackButton(viewWrapper: HTMLElement) {
    if (!canGoBack()) return;
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'detail-back-btn';
    button.title = '戻る';
    button.setAttribute('aria-label', '戻る');
    button.textContent = '‹';
    button.addEventListener('click', () => { void goBack(); });
    viewWrapper.prepend(button);
}
