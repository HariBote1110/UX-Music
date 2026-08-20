// WebView park/restore (Phase 2 of markdown/background-native-queue-plan.md).
//
// While the app window is hidden (close button -> HideWindowOnClose, or
// Cmd+H) and no YouTube embed session is active, the SPA parks itself into
// a tiny static page (public/parked.html) so the WebContent process can
// release the SPA's JS heap/DOM/image caches. Native (Go) playback keeps
// running throughout — see server/app_park.go for the Go-side half
// (WindowSetParked/ConsumePendingIntent) this module talks to.
//
// This file is deliberately the SINGLE seam for both directions:
//   - parkNow() is the only place that navigates away to /parked.html.
//   - restoreFromPark() is the only place that restores UI state /
//     replays a pending intent after the SPA reloads.
// A future Wails-fork DestroyWebView/RecreateWebView (Phase 3, only if
// Phase 2's measured saving is insufficient) only has to change what these
// two functions do, not any of their call sites.

import { getWailsApp, isWailsMode } from '../core/bridge.js';
import { isEmbedPlayerActive } from './youtube-embed-player.js';
import { showView } from '../core/navigation.js';
import { elements } from '../core/state.js';
import { handleQueuePlayEmbedEvent, handleRemotePlaySongEvent } from './playback-manager.js';

/** How long the window must stay hidden before the SPA parks itself. */
export const PARK_DELAY_MS = 15000;

const PARKED_UI_STATE_KEY = 'ux-music:parked-ui-state';

export interface ParkedUIState {
    viewId: string;
    scrollTop: number;
}

/**
 * Pure decision for whether the debounce timer firing should actually park
 * the SPA. All three conditions come from the design
 * (markdown/background-native-queue-plan.md Phase 2's §D): the window must
 * still be hidden when the timer fires (the user may have re-shown it in
 * the meantime), no YouTube embed session may be active (embed playback
 * needs the live SPA/IFrame), and this must be the Wails build (the
 * browser fallback has no parked page to go to).
 */
export function shouldPark(opts: { stillHidden: boolean; embedActive: boolean; isWails: boolean }): boolean {
    return opts.stillHidden && !opts.embedActive && opts.isWails;
}

/** JSON-encodes the (deliberately minimal) UI state saved before parking. */
export function serializeParkedUIState(state: ParkedUIState): string {
    return JSON.stringify(state);
}

/**
 * Decodes a previously-saved ParkedUIState, or null if there is nothing
 * to restore / the stored value is missing, malformed, or an unexpected
 * shape (defensive against a future format change reading an older
 * sessionStorage entry).
 */
export function deserializeParkedUIState(raw: string | null | undefined): ParkedUIState | null {
    if (!raw) return null;
    try {
        const parsed = JSON.parse(raw);
        if (parsed && typeof parsed === 'object' && typeof parsed.viewId === 'string' && typeof parsed.scrollTop === 'number') {
            return parsed as ParkedUIState;
        }
    } catch {
        // Malformed JSON — treat exactly like "nothing saved".
    }
    return null;
}

/** What ConsumePendingIntent() returned actually is, or null if there was nothing pending / it is unrecognised. */
export type PendingIntentKind = 'queue-play-embed' | 'remote-play-song' | null;

/**
 * Classifies a raw ConsumePendingIntent() result (see app_park.go's
 * emitOrQueueIntent — only these two event names are ever queued) so the
 * caller knows which existing handler to replay it through.
 */
export function classifyPendingIntent(intent: { event?: unknown; payload?: unknown } | null | undefined): PendingIntentKind {
    if (!intent) return null;
    if (intent.event === 'queue-play-embed') return 'queue-play-embed';
    if (intent.event === 'remote-play-song') return 'remote-play-song';
    return null;
}

let hideTimer: ReturnType<typeof setTimeout> | null = null;

function cancelParkTimer() {
    if (hideTimer !== null) {
        clearTimeout(hideTimer);
        hideTimer = null;
    }
}

/**
 * Saves a best-effort snapshot of "what the user was looking at" —
 * deliberately minimal per the design (queue/playback state is Go's, not
 * the SPA's, to restore). Best-effort: DOM state that is not trivially
 * available is simply omitted rather than chased down, since the SPA is
 * about to be torn down anyway.
 */
function captureUIState(): ParkedUIState {
    const activeNavLink = document.querySelector('.nav-link.active') as HTMLElement | null;
    const viewId = activeNavLink?.dataset?.view ?? 'track-view';
    const scrollTop = elements?.mainContent?.scrollTop ?? 0;
    return { viewId, scrollTop };
}

/**
 * The single park action: called once the PARK_DELAY_MS debounce timer
 * fires and shouldPark() says yes. Saves UI state, tells Go the SPA is
 * about to go away (WindowSetParked(true) — see app_park.go, this is what
 * makes startQueueItem/remote-play-song queue a pending intent instead of
 * emitting into the void), then navigates to the parked page.
 */
function parkNow() {
    try {
        sessionStorage.setItem(PARKED_UI_STATE_KEY, serializeParkedUIState(captureUIState()));
    } catch {
        // sessionStorage can throw (private mode, quota) — parking itself
        // must not be blocked by a best-effort UI snapshot failing.
    }
    void getWailsApp()?.WindowSetParked?.(true);
    location.replace('/parked.html');
}

/**
 * Wires the "app-visibility-changed" listener (server/app_media.go's
 * initAppVisibilityObserver) that drives the debounce-then-park flow.
 * Wails-only; a no-op when window.runtime is unavailable (browser
 * fallback preview).
 */
export function initParkBridge() {
    if (!window.runtime || typeof window.runtime.EventsOn !== 'function') {
        return;
    }
    window.runtime.EventsOn('app-visibility-changed', (payload: unknown) => {
        const hidden = Boolean((payload as { hidden?: unknown } | null)?.hidden);
        if (hidden) {
            cancelParkTimer();
            hideTimer = setTimeout(() => {
                hideTimer = null;
                if (shouldPark({ stillHidden: true, embedActive: isEmbedPlayerActive(), isWails: isWailsMode() })) {
                    parkNow();
                }
            }, PARK_DELAY_MS);
        } else {
            cancelParkTimer();
        }
    });
    // "wake-request" (app_park.go's emitOrQueueIntent) fires when a
    // pending intent was just queued because the SPA was parked — since
    // the parked page (not this one) is what's actually showing in that
    // case, this listener is inert then. It only matters as a defence
    // against the (currently believed impossible) case of the SPA still
    // being live with the debounce timer running when a wake-request
    // arrives: cancel the timer so a park doesn't race a wake.
    window.runtime.EventsOn('wake-request', () => {
        cancelParkTimer();
    });
}

/**
 * The single restore action: called once on every SPA startup (see
 * playback-manager.ts's initGoQueueBridge, right after QueueGetState()),
 * regardless of whether this startup followed a park cycle or is the
 * app's very first launch. Tells Go the SPA is live again
 * (WindowSetParked(false) — clears any stale pending-intent state on the
 * Go side too, see app_park.go), restores the best-effort UI snapshot if
 * one was saved, then drains and replays exactly one pending intent
 * (there is at most one — see app_park.go's single-slot design).
 */
export async function restoreFromPark() {
    void getWailsApp()?.WindowSetParked?.(false);

    let saved: ParkedUIState | null = null;
    try {
        saved = deserializeParkedUIState(sessionStorage.getItem(PARKED_UI_STATE_KEY));
        sessionStorage.removeItem(PARKED_UI_STATE_KEY);
    } catch {
        // Same best-effort contract as captureUIState.
    }
    if (saved) {
        try {
            await showView(saved.viewId);
            if (elements?.mainContent) {
                elements.mainContent.scrollTop = saved.scrollTop;
            }
        } catch (e) {
            console.error('[Park] Failed to restore UI state:', e);
        }
    }

    const intent = await getWailsApp()?.ConsumePendingIntent?.();
    switch (classifyPendingIntent(intent)) {
        case 'queue-play-embed':
            await handleQueuePlayEmbedEvent(intent.payload);
            break;
        case 'remote-play-song':
            handleRemotePlaySongEvent(intent.payload);
            break;
        default:
            break;
    }
}
