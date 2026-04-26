import { elements } from '../core/state.js';

const DEFAULT_TOAST_MS = 4000;

let notificationTimeout;

/**
 * トースト表示。呼び出し後に `hideNotification` しなくても既定時間で非表示にする（重複表示は前の予約を上書き）。
 * @param {string} message
 * @param {number|boolean} [autoHide] - 数: 非表示までの ms。`false` では非表示予約を付けない（`hideNotification` まで出し続け）。
 *   文字列（例: 旧来の 'error'）は無視し、既定 ms の自動非表示を行う。
 */
export function showNotification(message, autoHide) {
    if (notificationTimeout) {
        clearTimeout(notificationTimeout);
        notificationTimeout = null;
    }
    elements.notificationText.textContent = message;
    elements.notificationToast.classList.add('show');
    elements.notificationToast.classList.remove('hidden');

    let scheduleMs = DEFAULT_TOAST_MS;
    if (autoHide === false) {
        return;
    }
    if (typeof autoHide === 'number' && autoHide > 0) {
        scheduleMs = autoHide;
    }

    notificationTimeout = setTimeout(() => {
        elements.notificationToast.classList.remove('show');
        elements.notificationToast.classList.add('hidden');
        notificationTimeout = null;
    }, scheduleMs);
}

export function hideNotification(delay = 0) {
    if (notificationTimeout) {
        clearTimeout(notificationTimeout);
        notificationTimeout = null;
    }
    notificationTimeout = setTimeout(() => {
        elements.notificationToast.classList.remove('show');
        elements.notificationToast.classList.add('hidden');
        notificationTimeout = null;
    }, delay);
}
