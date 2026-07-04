import { beforeEach, describe, expect, it, vi } from 'vitest';

function createFakeElement() {
    const classes = new Set<string>(['hidden']);
    return {
        textContent: '',
        classList: {
            add: (c: string) => classes.add(c),
            remove: (c: string) => classes.delete(c),
            contains: (c: string) => classes.has(c),
        },
    };
}

const notificationToast = createFakeElement();
const notificationText = createFakeElement();

vi.mock('../core/state.js', () => ({
    elements: {
        notificationToast,
        notificationText,
    },
}));

describe('notification timer conflicts', () => {
    beforeEach(() => {
        vi.useFakeTimers();
        vi.resetModules();
        notificationToast.classList.add('hidden');
        notificationToast.classList.remove('show');
        notificationText.textContent = '';
    });

    it('keeps the toast visible for the last shown message when a new notification arrives before a pending hide fires', async () => {
        const { showNotification, hideNotification } = await import('./notification.js');

        // First notification schedules a hide via an explicit hideNotification call.
        showNotification('最初の通知');
        hideNotification(1000);

        // Before that hide fires, a second notification is shown with its own longer auto-hide.
        vi.advanceTimersByTime(500);
        showNotification('2番目の通知', 5000);

        // Advance past the point where the first hide timer would have fired.
        vi.advanceTimersByTime(600);

        // The toast must still be visible showing the second message — the stale hide
        // timer from the first notification must not have hidden it early.
        expect(notificationToast.classList.contains('show')).toBe(true);
        expect(notificationToast.classList.contains('hidden')).toBe(false);
        expect(notificationText.textContent).toBe('2番目の通知');

        // Once the second notification's own auto-hide elapses, it should hide.
        vi.advanceTimersByTime(4500);
        expect(notificationToast.classList.contains('show')).toBe(false);
        expect(notificationToast.classList.contains('hidden')).toBe(true);
    });

    it('only the last scheduled hide takes effect when hideNotification is called multiple times in a row', async () => {
        const { showNotification, hideNotification } = await import('./notification.js');

        showNotification('通知', false);
        hideNotification(2000);
        hideNotification(4000);

        vi.advanceTimersByTime(2500);
        expect(notificationToast.classList.contains('show')).toBe(true);

        vi.advanceTimersByTime(2000);
        expect(notificationToast.classList.contains('show')).toBe(false);
    });

    it('cancels a previously scheduled hide when a persistent (autoHide: false) notification follows it', async () => {
        const { showNotification, hideNotification } = await import('./notification.js');

        hideNotification(1000);
        showNotification('進行中の通知', false);

        // The stale hide timer from before must not fire and hide the persistent notification.
        vi.advanceTimersByTime(2000);
        expect(notificationToast.classList.contains('show')).toBe(true);
        expect(notificationText.textContent).toBe('進行中の通知');
    });
});
