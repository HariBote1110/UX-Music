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
