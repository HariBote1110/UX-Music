// WebView park/restore (Phase 3, corrected design — see
// progress/webview-parking.md's Phase 3 root-cause-correction section).
//
// While the app window is hidden (close button -> HideWindowOnClose, or
// Cmd+H) and no YouTube embed session is active, Go parks the SPA by
// actually DESTROYing the WKWebView (via the Wails fork's
// runtime.WindowUnloadWebView — see FORK_NOTES.md in
// github.com/HariBote1110/wails, branch ux-music/webview-destroy) so the
// WebContent process itself exits and its memory is returned to the OS
// immediately. Native (Go) playback keeps running throughout.
//
// IMPORTANT — the debounce timer and the park decision itself now live
// entirely in Go (server/app_park.go's startParkTimer/attemptPark, driven
// by server/app_media.go's handleAppVisibilityChanged), not here. The first
// cut of this design ran a 15s setTimeout in this very file, in the WebView
// that was about to be hidden — independent re-testing found the window
// sitting hidden for 9.5 minutes with WebContent still fully alive and no
// park at all, because WebKit suspends/throttles JS timers in
// hidden/occluded pages. A native NSApplicationDidHide/DidUnhide
// notification driving a Go time.AfterFunc has no such throttling, so Go
// now owns the whole decision — see app_park.go's file-level comment for
// the full account.
//
// Because Go can therefore destroy the webview at any point after the
// window goes hidden with no further round-trip to JS, this file no longer
// tries to pull a UI snapshot from JS "at the moment of parking" (there is
// no such moment observable from here any more). Instead it pushes a
// snapshot to Go opportunistically, well ahead of any actual park:
//   - core/navigation.js's showView calls core/bridge.js's
//     recordParkUIState on every view change;
//   - initParkBridge below does the same, best-effort, on the
//     app-visibility-changed hidden=true event (the moment the window is
//     hidden, before any debounce — this event itself is native-driven and
//     not subject to the same timer throttling that broke the old design).
//
// This file's only remaining responsibilities are that best-effort push and
// restoreFromPark — draining the UI snapshot and any pending intent once
// the SPA reboots after Go recreates the webview (see server/app_park.go's
// ConsumeParkedUIState/ConsumePendingIntent).

import { getWailsApp, recordParkUIState } from '../core/bridge.js';
import { showView } from '../core/navigation.js';
import { elements } from '../core/state.js';
import { handleQueuePlayEmbedEvent, handleRemotePlaySongEvent } from './playback-manager.js';

export interface ParkedUIState {
    viewId: string;
    scrollTop: number;
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
 * nothing having been recorded yet.
 */
export function parseParkedUIState(raw: unknown): ParkedUIState | null {
    if (!raw || typeof raw !== 'object') return null;
    const obj = raw as Record<string, unknown>;
    if (typeof obj.viewId === 'string' && typeof obj.scrollTop === 'number') {
        return { viewId: obj.viewId, scrollTop: obj.scrollTop };
    }
    return null;
}

/**
 * Best-effort snapshot of "what the user was looking at", read from the DOM
 * directly (unlike navigation.js's showView, this file does not otherwise
 * know the current viewId) — used only by the hidden=true best-effort push
 * below.
 */
function captureUIState(): ParkedUIState {
    const activeNavLink = document.querySelector('.nav-link.active') as HTMLElement | null;
    const viewId = activeNavLink?.dataset?.view ?? 'track-view';
    const scrollTop = elements?.mainContent?.scrollTop ?? 0;
    return { viewId, scrollTop };
}

/**
 * Wires the "app-visibility-changed" listener (server/app_media.go's
 * initAppVisibilityObserver) purely for the best-effort UI-state push on
 * hidden=true — parking itself is entirely Go-driven (see the file header).
 * Wails-only; a no-op when window.runtime is unavailable (browser fallback
 * preview).
 */
export function initParkBridge() {
    if (!window.runtime || typeof window.runtime.EventsOn !== 'function') {
        return;
    }
    window.runtime.EventsOn('app-visibility-changed', (payload: unknown) => {
        const hidden = Boolean((payload as { hidden?: unknown } | null)?.hidden);
        if (hidden) {
            const { viewId, scrollTop } = captureUIState();
            recordParkUIState(viewId, scrollTop);
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
