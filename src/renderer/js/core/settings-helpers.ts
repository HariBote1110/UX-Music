/**
 * Normalises persisted settings payloads from the main process / bridge.
 * Non-object results collapse to `{}` so property reads use consistent defaults.
 */
export function normalizeSettings(raw: unknown): Record<string, unknown> {
    if (raw != null && typeof raw === 'object' && !Array.isArray(raw)) {
        return raw as Record<string, unknown>;
    }
    return {};
}

/**
 * Loose shape for renderer reads (settings modal, audio devices, feature flags).
 * Values ultimately come from persisted JSON; fields are optional.
 */
export interface RendererSettingsRead {
    audioOutputId?: string;
    hiddenDeviceIds?: string[];
    targetLoudness?: number;
    youtubePlaybackMode?: string;
    youtubeDownloadQuality?: string;
    importMode?: string;
    cdRipMode?: string;
    visualizerMode?: string;
    groupAlbumArt?: boolean;
    analysedQueue?: { enabled?: boolean; decayDays?: number };
    enableEasterEggs?: boolean;
    enableYouTube?: boolean;
    uiTheme?: string;
    syncMinFreeSpaceGB?: number;
    syncCachePolicy?: string;
    syncPreferredFormat?: string;
}

/**
 * Loads settings via `electronAPI.invoke('get-settings')` and normalises the result.
 * Returns `{}` when the API is missing or invocation fails.
 */
export async function loadNormalizedSettings(): Promise<Record<string, unknown>> {
    const electronAPI = window.electronAPI;
    if (!electronAPI?.invoke) {
        return {};
    }
    try {
        const raw: unknown = await electronAPI.invoke('get-settings');
        return normalizeSettings(raw);
    } catch {
        return {};
    }
}

/**
 * Same as {@link loadNormalizedSettings} but typed for typical UI property access.
 */
export async function loadRendererSettings(): Promise<RendererSettingsRead> {
    const raw = await loadNormalizedSettings();
    return raw as RendererSettingsRead;
}

/**
 * Reflects a persisted `isShuffled` setting into app state and syncs the
 * shuffle button's active class. No-op when `isShuffled` is not a boolean.
 */
export function applyShuffleSetting(
    settings: { isShuffled?: unknown },
    state: { isShuffled: boolean },
    elements: { shuffleBtn: HTMLElement | null }
): void {
    if (typeof settings.isShuffled === 'boolean') {
        state.isShuffled = settings.isShuffled;
        if (elements.shuffleBtn) elements.shuffleBtn.classList.toggle('active', state.isShuffled);
    }
}
