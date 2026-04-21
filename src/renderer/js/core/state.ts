/**
 * Application state (`state`) and DOM element bag (`elements`).
 * Split across `app-state.ts` and `dom-elements.ts` for clearer module boundaries.
 */

export { PLAYBACK_MODES, state, type AppState } from './app-state.js';
export { elements, initElements } from './dom-elements.js';
