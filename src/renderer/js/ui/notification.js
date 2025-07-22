import { elements } from '../state.js';

let notificationTimeout;

export function showNotification(message) {
    if (notificationTimeout) {
        clearTimeout(notificationTimeout);
    }
    elements.notificationText.textContent = message;
    elements.notificationToast.classList.add('show');
    elements.notificationToast.classList.remove('hidden');
}

export function hideNotification(delay = 0) {
    if (notificationTimeout) {
        clearTimeout(notificationTimeout);
    }
    notificationTimeout = setTimeout(() => {
        elements.notificationToast.classList.remove('show');
        elements.notificationToast.classList.add('hidden');
    }, delay);
}