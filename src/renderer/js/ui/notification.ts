import { elements } from '../core/state.js';

const DEFAULT_TOAST_MS = 4000;

let notificationTimeout: ReturnType<typeof setTimeout> | null = null;

export function showNotification(message: string, autoHide: number | boolean = DEFAULT_TOAST_MS) {
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
