// WebView park/restore (Phase 3 of markdown/background-native-queue-plan.md).
//
// While the app window is hidden (close button -> HideWindowOnClose, or
// Cmd+H) and no YouTube embed session is active, the SPA parks itself by
// asking Go to actually DESTROY the WKWebView (via the Wails fork's
// runtime.WindowUnloadWebView — see FORK_NOTES.md in
// github.com/HariBote1110/wails, branch ux-music/webview-destroy) so the
// WebContent process itself exits and its memory is returned to the OS
// immediately. This replaced Phase 2's approach (navigating to a small
// static /parked.html placeholder page, now removed): that approach worked,
// but WebKit only released the freed pages back to the OS after roughly
// 4.5 minutes — see progress/webview-parking.md's measurement-correction
// section — while the WKWebView instance and its WebContent process stayed
// alive the whole time. Destroying the webview outright is immediate.
// Native (Go) playback keeps running throughout — see server/app_park.go
// for the Go-side half (WindowParkWebView/WindowSetParked/
// ConsumeParkedUIState/ConsumePendingIntent) this module talks to.
//
// Because destroying the webview also destroys every bit of JS state
// (including sessionStorage — there is no longer a page to navigate away
// from, the whole WebContent process exits), the small "what was I looking
// at" UI snapshot that Phase 2 kept in sessionStorage now has to live in Go
// instead (see captureUIState/WindowParkWebView/ConsumeParkedUIState). For
// the same reason, un-parking can no longer be initiated by a listener
// inside the parked page (there is no parked page, and no JS at all, while
// parked) — Go itself calls runtime.WindowReloadWebView once the window is
// shown again or a new intent arrives (see app_media.go's
// handleAppVisibilityChanged and app_park.go's emitOrQueueIntent), which
// recreates the webview and reloads the SPA from scratch, landing back here
// via restoreFromPark on startup exactly like a fresh launch would.
//
// This file is deliberately the SINGLE seam for both directions:
//   - parkNow() is the only place that asks Go to destroy the webview.
//   - restoreFromPark() is the only place that restores UI state /
//     replays a pending intent after the SPA reloads.

import { getWailsApp, isWailsMode } from '../core/bridge.js';
import { isEmbedPlayerActive } from './youtube-embed-player.js';
import { showView } from '../core/navigation.js';
import { elements } from '../core/state.js';
import { handleQueuePlayEmbedEvent, handleRemotePlaySongEvent } from './playback-manager.js';

/** How long the window must stay hidden before the SPA parks itself. */
export const PARK_DELAY_MS = 15000;

export interface ParkedUIState {
    viewId: string;
    scrollTop: number;
}

/**
 * Pure decision for whether the debounce timer firing should actually park
 * the SPA. All three conditions come from the design
 * (markdown/background-native-queue-plan.md Phase 2's §D, unchanged by
 * Phase 3): the window must still be hidden when the timer fires (the user
 * may have re-shown it in the meantime), no YouTube embed session may be
 * active (embed playback needs the live SPA/IFrame), and this must be the
 * Wails build (the browser fallback has no Go side to hand the webview
 * lifecycle to).
 */
export function shouldPark(opts: { stillHidden: boolean; embedActive: boolean; isWails: boolean }): boolean {
    return opts.stillHidden && !opts.embedActive && opts.isWails;
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

/**
 * Validates a raw ConsumeParkedUIState() result (a plain object handed back
 * by Go, or null/undefined when nothing was saved) against the expected
 * ParkedUIState shape, returning null for anything that does not match —
 * defensive against a future format change, an App.d.ts drift, or simply
 * nothing having been parked yet.
 */
export function parseParkedUIState(raw: unknown): ParkedUIState | null {
    if (!raw || typeof raw !== 'object') return null;
    const obj = raw as Record<string, unknown>;
    if (typeof obj.viewId === 'string' && typeof obj.scrollTop === 'number') {
        return { viewId: obj.viewId, scrollTop: obj.scrollTop };
    }
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
 * Captures a best-effort snapshot of "what the user was looking at" —
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
 * fires and shouldPark() says yes. Hands the UI snapshot to Go and asks it
 * to destroy the webview (see server/app_park.go's WindowParkWebView,
 * which itself marks the app parked — no separate WindowSetParked(true)
 * call is needed here). Nothing after this call may ever run: the
 * WebContent process backing this very script is being torn down, so this
 * is deliberately fire-and-forget with no awaited continuation.
 */
function parkNow() {
    void getWailsApp()?.WindowParkWebView?.(captureUIState() as unknown as Record<string, unknown>);
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
}

/**
 * The single restore action: called once on every SPA startup (see
 * playback-manager.ts's initGoQueueBridge, right after QueueGetState()),
 * regardless of whether this startup followed a park cycle or is the
 * app's very first launch. Tells Go the SPA is live again
 * (WindowSetParked(false) — clears any stale pending-intent/UI-state on
 * the Go side too, see app_park.go), restores the best-effort UI snapshot
 * Go handed back if one was saved, then drains and replays exactly one
 * pending intent (there is at most one — see app_park.go's single-slot
 * design).
 */
export async function restoreFromPark() {
    void getWailsApp()?.WindowSetParked?.(false);

    const rawState = await getWailsApp()?.ConsumeParkedUIState?.();
    const saved = parseParkedUIState(rawState);
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
