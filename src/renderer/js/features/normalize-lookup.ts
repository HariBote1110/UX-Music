// Pure helpers for the normalize-result handler.
// Extracted so unit tests can cover the id↔path fallback and the
// renderer→backend payload narrowing without a DOM / Wails runtime.

export interface NormalizeResultPayload {
    id?: string | null;
    path?: string | null;
}

export interface NormalizeFileLike {
    id: string;
    path: string;
}

export function escapeHtmlText(value: unknown): string {
    return String(value ?? '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

/**
 * Looks up the renderer-side file entry that an incoming normalize-worker-result
 * refers to. Falls back to matching by file path when the id does not appear in
 * the map — Wails has historically coerced numeric-looking ids across the bridge,
 * which caused the result to be silently dropped (see commit e121036).
 */
export function findNormalizeFileForResult<T extends NormalizeFileLike>(
    files: ReadonlyMap<string, T>,
    payload: NormalizeResultPayload,
): T | undefined {
    const id = payload?.id;
    if (typeof id === 'string' && id !== '') {
        const byId = files.get(id);
        if (byId) return byId;
    }
    const path = payload?.path;
    if (typeof path === 'string' && path !== '') {
        for (const f of files.values()) {
            if (f.path === path) return f;
        }
    }
    return undefined;
}

export interface JobFilePayload {
    id: string;
    path: string;
    gain: number;
}

/**
 * Narrows a renderer-side file (with currentLufs, name, selected, etc.) down to
 * the three fields the Go backend actually reads. Keeping the wire format small
 * also avoids ambiguous coercions on the Wails JSON bridge.
 */
export function toJobFilePayload(file: {
    id: string;
    path: string;
    gain?: number;
    [k: string]: unknown;
}): JobFilePayload {
    const gain = Number(file.gain);
    return {
        id: file.id,
        path: file.path,
        gain: Number.isFinite(gain) ? gain : 0,
    };
}
